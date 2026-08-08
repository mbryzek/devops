require 'json'
require 'securerandom'
require 'shellwords'
require 'socket'
require 'time'
require 'agent/ci'
require 'agent/heap'
require 'agent/merge_lane'
require 'agent/paths'
require 'agent/shell'

# The fleet verify job (ISS-848): the thing that PRODUCES the `ci` check the
# merge lane reads.
#
# ISS-763 produced it from GitHub Actions on self-hosted runners, and every piece
# of machinery that design needed — a reservation file, a flock semaphore, a
# subtraction inside Agent::Tick#session_capacity, a per-repo-per-box human
# install that mints a registration token — existed for ONE reason: Actions is a
# SECOND SCHEDULER on hardware `Agent::Tick` already schedules. Neither can see
# the other, so they need an agreed split. None of that is about verifying code.
# Delete the second scheduler and all of it goes.
#
# What is left is the job itself, and it is deliberately NOT a Claude session:
#
#     checkout <repo>@<sha> (detached)  ->  ci/build.sh  ->  post a commit status
#
# A modelless job with a fixed command, an exit code and a deadline. Scoping it
# as "a session that runs the tests" would put an LLM in the one loop that has to
# be deterministic, and would bill tokens per re-verification — of which there
# are many, for a reason worth stating plainly because it is the whole
# requirement:
#
#   UNDER THE LANE'S AHEAD INVARIANT, EVERY MERGE INVALIDATES EVERY OTHER OPEN PR
#   IN THAT REPO. `update_branch!` merges the base under each one, which pushes a
#   new head sha, which needs a NEW check on THAT sha — the FRESH invariant
#   refuses a check attached to any earlier push. With a ~50-deep queue that is
#   verification on the order of PRs x merges, each answering in minutes,
#   triggered by a push nobody is watching. Actions gave that trigger for free;
#   replacing it means the fleet has to produce it, which is what `scan` is.
#
# FOUR PROPERTIES, and each is a way this lies rather than four features:
#
#   enrolment   A repo is verified here exactly when `ci/build.sh` exists AT THE
#               HEAD SHA. Same shape as the rule it replaces (enrolment was the
#               presence of a `ci` check, so there is no second registry to drift
#               from the workflows that exist) with one improvement: the
#               enrolling commit is one the lane can read at the sha it is
#               verifying.
#   dedup       Fleet-wide, and it lives on GitHub rather than in a file on this
#               runner, because two boxes scanning the same repo must not both
#               build the same sha. The `pending` status IS the dedup record:
#               posted at ENQUEUE rather than at start, read back, and the box
#               whose token is not the current one drops the job.
#   silence     A hung job is the one outcome the lane cannot recover from —
#               `:ci_pending` is indistinguishable from a dead runner, so it
#               waits forever on both. Everything here is bounded and every exit
#               path posts a terminal status.
#   freshness   Post on the sha you actually BUILT, never on the current head. If
#               the branch moved underneath the build, the lane's FRESH check
#               rejects the result, which is correct — re-pointing it at the new
#               head would be a green measured on a tree nobody built.
module Agent
  module Verify
    # THE ENROLMENT ARTIFACT. A repo whose head sha carries this file is verified
    # by the fleet; one that does not is not, and reports `:no_ci_verdict` on
    # every PR exactly as it does today.
    #
    # A script rather than a declarative block, and the reason survives verbatim
    # from the workflow template this replaces: a pipeline reports only its LAST
    # command's status, so a `claude-db start | grep | sed` that FAILED exits 0
    # with `CONF_DB_DEV_URL` unset — and unset is the shared `:5432`, which is
    # Mike's own database (ISS-735). `set -euo pipefail` in a file, with one
    # exit status, is the only shape that cannot do that.
    BUILD_SCRIPT = "ci/build.sh".freeze

    # What the build script may declare it needs from the machine, as a comment
    # the script itself carries:
    #
    #     # ci-needs: docker, registry, database
    #
    # In the script rather than in a registry here for the same reason enrolment
    # is: the repo says what its own build touches, at the sha being built, so a
    # suite that stops needing Docker stops being held to a Docker daemon in the
    # same commit. Absent means "nothing beyond disk", which is right for a Node
    # unit suite and wrong for nothing.
    NEEDS_DIRECTIVE = /^\s*#\s*ci-needs:\s*(.+)$/.freeze

    # The check name, taken from the lane rather than restated: this module and
    # Agent::MergeLane must never be able to disagree about the one string that
    # ties a build to a merge.
    CHECK = Agent::MergeLane::CI_CHECK

    # The base branch every repo in the lane uses. A constant rather than a
    # lookup because the cold build below needs it BEFORE it has a PR to read
    # `baseRefName` off, and one extra API call per repo per hour to learn a fact
    # that has been "main" in every one of these repos forever is not worth it.
    DEFAULT_BRANCH = "main".freeze

    # How often a runner walks the lane looking for work.
    #
    # NOT every tick. The tick fires every 30 seconds and the walk is one `gh pr
    # list` per repo, so at tick cadence two boxes would spend ~3,000 API calls
    # an hour to learn the same thing. Three minutes is far inside the time a
    # build takes, so the latency it adds is not measurable against the thing
    # being waited for.
    SCAN_INTERVAL_SECONDS = 180

    # The per-pass cap, and it is failure mode 2: every merge invalidates every
    # sibling PR, so ONE merge in a 50-PR repo makes 49 PRs need a new check at
    # once. Without a cap the first scan after a merge would try to fill the
    # whole fleet with verify jobs and starve every agent session on it.
    #
    # What is dropped is LOGGED rather than silently truncated — a cap nobody can
    # see reads as "everything is covered" when it is not — and the next pass
    # three minutes later picks up where this one stopped.
    ENQUEUE_CAP = 4

    # The build's own wall-clock deadline, enforced by this process rather than
    # by the tick, because the tick is the BACKSTOP and not the mechanism: a
    # runner whose launchd job is unloaded still has to answer the PR it took.
    # A job that dies silently holds the lane forever (failure mode 1), so the
    # deadline posts `failure` with the infrastructure marker instead.
    BUILD_TIMEOUT_SECONDS = 45 * 60

    # The tick's own hard timeout on a verify job, deliberately LONGER than the
    # build's: the ordinary deadline belongs to the process doing the work, and
    # this only fires for a worker that is itself wedged — one that never reached
    # its own watchdog. Overlapping them would make the tick race the worker for
    # which of the two posts the result.
    JOB_TIMEOUT_SECONDS = BUILD_TIMEOUT_SECONDS + (10 * 60)

    # How often a runner even LOOKS at the base branch, and how stale the newest
    # `ci` status on it may be before it is rebuilt cold.
    #
    # THE COLD BUILD ON `main` IS WHAT NOTICES THE WARM PATH HAS BEEN LYING. It
    # was a `schedule:` trigger in the workflow this replaces; here it is the
    # same rule the PR path uses, applied to the tip of `main` — no status, or
    # one older than a day, means build it, cold. That covers the nightly AND the
    # push trigger in one rule, because a merge moves the tip and the new tip has
    # no status.
    MAIN_SCAN_INTERVAL_SECONDS = 60 * 60
    MAIN_MAX_STATUS_AGE_SECONDS = 24 * 60 * 60

    # A `pending` status this old is ABANDONED, not in flight. The box that
    # posted it rebooted, or its worker was killed hard enough to skip both its
    # own watchdog and the reap. Deliberately above JOB_TIMEOUT_SECONDS, so a job
    # that is merely slow is never stolen from the runner still working it.
    STALE_PENDING_SECONDS = JOB_TIMEOUT_SECONDS + (15 * 60)

    # GitHub's own limit on a status description. Clipped rather than rejected:
    # the description is where a human learns "fix the machine, not the diff" and
    # where the log path lives, so a long one must degrade to a short one and
    # never to a failed POST.
    DESCRIPTION_LIMIT = 140

    # Bounds on the `gh` and `git` calls here, for the reason every timeout in
    # lib/agent exists: this runs inside a tick that holds a lock, and an
    # unbounded subprocess against a stalled connection is a wedged runner rather
    # than a failure (ISS-740).
    API_TIMEOUT_SECONDS = 60
    GIT_TIMEOUT_SECONDS = 15 * 60

    # How many enrolment answers to keep. A sha is IMMUTABLE, so "does
    # ci/build.sh exist at abc123" is a fact that can be cached forever — which
    # is the whole point: without it every scan re-asks the same question about
    # the same unenrolled PRs, and ten repos with no CI would burn the API budget
    # that the enrolled ones need.
    ENROLMENT_CACHE_LIMIT = 500

    # Agent::Errors source for a verify job that could not even be handed a
    # result. Distinct from Agent::Ci::ERROR_SOURCE, which is the preflight's:
    # "this box cannot produce a verdict" and "this box cannot POST one" are
    # different repairs, and a streak that mixed them would name neither.
    ERROR_SOURCE = "ci_verify".freeze

    # One unit of work. `pr` is nil for the cold build on `main`, which is the
    # only candidate with no pull request behind it.
    Candidate = Struct.new(:repo, :pr, :sha, :event, keyword_init: true) do
      def key = Agent::Verify.key(repo, sha)
      def clean? = Agent::Ci.clean_build?(event: event)
      def label
        name = Agent::MergeLane.bare(repo)
        pr ? "#{name}##{pr}" : "#{name}@#{Agent::Verify.short(sha)}"
      end
    end

    module_function

    def short(sha) = sha.to_s[0, 8]

    def hostname
      Socket.gethostname
    rescue StandardError
      "unknown"
    end

    # The job's identity on disk and in the status description. The sha is what
    # makes it unique — a repo can have several PRs waiting and a PR can have
    # several shas — and it is truncated only for legibility in a path.
    def key(repo, sha) = "#{Agent::MergeLane.bare(repo)}-#{sha.to_s[0, 12]}"

    # ---------------- the session database name ----------------

    # RUN, ATTEMPT AND SHARD, all three, exactly as the workflow this replaces
    # required — because `claude-db` keys a database on this string and each
    # missing part is a measured failure:
    #
    #   run      the repo and the sha. Two PRs verifying at once on one box must
    #            not share a database.
    #   attempt  the epoch second the job started, plus the pid. A retry of a sha
    #            whose predecessor's `claude-db end` never fired would otherwise
    #            inherit its rows — and a counter would not be enough here, since
    #            TWO MACHINES may verify one sha (harmless by design, and only
    #            harmless while their databases are distinct).
    #   shard    reserved. Nothing shards yet; it is a parameter rather than a
    #            constant so that adding sharding cannot forget it, which is the
    #            failure the workflow's `matrix` out-of-scope bug produced.
    #
    # The suite is not idempotent against its own database: eight consecutive
    # platform runs on ONE session database, on unmodified main, went from 3
    # failures to 39 as `tasks` reached 131,632 rows (ISS-761, ISS-801). Freshness
    # is not a nicety here; `ci/build.sh` resets on top of this as well.
    def session_id(repo, sha, attempt: nil, shard: 1, pid: Process.pid, now: Time.now)
      attempt ||= "#{now.to_i}-#{pid}"
      "ci-#{Agent::MergeLane.bare(repo)}-#{short(sha)}-#{attempt}-s#{shard}"
    end

    # ---------------- reads ----------------

    # `gh` or `git` missing is the same fact as one that ran and failed HERE — this
    # runner cannot do the thing — so it is flattened into a failing Result rather
    # than left as an exception every call site would have to rescue for itself.
    # 127 is the shell's own "command not found", so `summary` reads as a status
    # rather than as a blank.
    NotInstalled = Struct.new(:success?, :exitstatus)

    def capture(cmd, timeout: API_TIMEOUT_SECONDS, chdir: nil)
      Agent::Shell.capture(*cmd, timeout: timeout, chdir: chdir)
    rescue Errno::ENOENT
      Agent::Shell::Result.new(output: "#{cmd.first} is not installed",
                               status: NotInstalled.new(false, 127),
                               timed_out: false, timeout: timeout)
    end

    def read(cmd, timeout: API_TIMEOUT_SECONDS)
      result = capture(cmd, timeout: timeout)
      result.ok? ? result.output : nil
    end

    # Does `ci/build.sh` exist at this exact commit?
    #
    # Cached, permanently, because the answer for a given sha can never change —
    # see ENROLMENT_CACHE_LIMIT. A LOOKUP THAT FAILED IS NOT CACHED and is not
    # read as "no": a `gh` blip must cost one skipped pass, never an enrolment
    # silently withdrawn for the life of a sha.
    def enrolled?(repo, sha)
      slug = Agent::MergeLane.qualify(repo)
      cached = enrolment_cache["#{slug}@#{sha}"]
      return cached unless cached.nil?

      result = capture(["gh", "api", "repos/#{slug}/contents/#{BUILD_SCRIPT}?ref=#{sha}", "--jq", ".sha"])
      # A 404 is a definite NO — `gh api` exits non-zero on it, so the exit status
      # alone cannot tell an absent file from an unreachable API. The body can:
      # GitHub answers a missing path with a "Not Found" document.
      return remember_enrolment(slug, sha, true) if result.ok?
      return remember_enrolment(slug, sha, false) if result.output.to_s.include?("Not Found")
      nil
    end

    def enrolment_cache
      @enrolment_cache ||= Agent::Paths.read_json(Agent::Paths.verify_enrolment_file) || {}
    end

    def remember_enrolment(slug, sha, answer)
      cache = enrolment_cache
      cache["#{slug}@#{sha}"] = answer
      # Ruby hashes preserve insertion order, so dropping from the front drops the
      # oldest answers — which are the shas least likely to be asked about again.
      cache.shift while cache.length > ENROLMENT_CACHE_LIMIT
      @enrolment_cache = cache
      Agent::Paths.write_json(Agent::Paths.verify_enrolment_file, cache)
      answer
    rescue StandardError
      # The cache is an optimisation. A state dir it cannot write costs API calls,
      # not correctness, and must never turn a scan into a crash.
      answer
    end

    # The newest `ci` COMMIT STATUS on a sha, as GitHub's combined-status endpoint
    # reports it — one entry per context, latest wins, which is exactly the dedup
    # semantics this relies on.
    #
    # Deliberately NOT the checks API: what this needs to know is "is the pending
    # status on this sha the one I just posted", and a CheckRun cannot answer that
    # because nothing here posts one.
    def latest_status(repo, sha)
      slug = Agent::MergeLane.qualify(repo)
      out = read(["gh", "api", "repos/#{slug}/commits/#{sha}/status",
                  "--jq", ".statuses[] | select(.context == \"#{CHECK}\")"])
      return nil if out.nil? || out.strip.empty?
      JSON.parse(out.lines.first)
    rescue JSON::ParserError
      nil
    end

    def post_status(repo, sha, state:, description:)
      slug = Agent::MergeLane.qualify(repo)
      capture(["gh", "api", "--method", "POST", "repos/#{slug}/statuses/#{sha}",
               "-f", "state=#{state}", "-f", "context=#{CHECK}",
               "-f", "description=#{clip(description)}"]).ok?
    end

    def clip(text) = text.to_s[0, DESCRIPTION_LIMIT]

    # ---------------- the scan ----------------

    # Every repo the lane may act on, minus the ones whose merge IS a deploy.
    #
    # `devops` is excluded here as well as in the lane, and for a reason worth
    # stating rather than inheriting: a `ci` check on devops would be useful to a
    # human and buys no automation, because nothing may ever merge that repo
    # automatically. Spending fleet capacity to produce a signal no machine will
    # act on is capacity the enrolled repos need.
    # QUALIFIED, and that is not cosmetic. `Agent::MergeLane::LANE_REPOS` holds
    # bare names, and `gh pr list --repo playbook-admin` does not resolve one
    # outside a checkout of it — it exits non-zero, which `capture` reads as no
    # output, which `open_prs` reads as NO OPEN PULL REQUESTS. A scan built on the
    # bare names finds nothing, forever, and says "everything is covered".
    def repos
      (Agent::MergeLane::LANE_REPOS - Agent::MergeLane::SELF_DEPLOYING_REPOS).map { |r| Agent::MergeLane.qualify(r) }
    end

    # Has enough time passed to walk the lane again? Marks the pass as taken, so
    # a scan that finds nothing does not re-run 30 seconds later.
    def scan_due?(now: Time.now, interval: SCAN_INTERVAL_SECONDS, file: Agent::Paths.verify_scan_file)
      last = Agent::Paths.read_json(file)
      at = last && last["at"]
      parsed = (Time.parse(at) if at) rescue nil
      return false if parsed && (now - parsed) < interval
      true
    end

    def mark_scanned(now: Time.now, file: Agent::Paths.verify_scan_file)
      previous = Agent::Paths.read_json(file) || {}
      Agent::Paths.write_json(file, previous.merge("at" => now.utc.iso8601))
    end

    # THE ENQUEUE SIGNAL, and it is the lane's own `:no_ci_verdict` read from the
    # other side: a PR whose head sha carries no `ci` entry is a PR nothing has
    # verified.
    #
    # Reading the ROLLUP rather than the statuses endpoint is what makes this
    # coexist with a repo that still produces `ci` from GitHub Actions: an Actions
    # CheckRun and a commit status both appear there, so a repo Actions is already
    # answering for is never enqueued here and the two cannot both post `ci` on
    # one sha.
    #
    # Drafts are skipped — the author has not said it is ready, and the lane skips
    # them too, so verifying one spends a build on a PR nothing can act on.
    def pr_candidates(repo, now: Time.now)
      Agent::MergeLane.open_prs(repo).filter_map do |raw|
        next if raw["isDraft"] || raw["isCrossRepository"]
        sha = raw["headRefOid"].to_s
        next if sha.empty?
        next unless needs_check?(repo, raw, now: now)
        Candidate.new(repo: repo, pr: raw["number"], sha: sha, event: "pull_request")
      end
    end

    # No `ci` entry at all, or one this fleet abandoned.
    #
    # THE SECOND ARM IS THE SELF-HEAL for failure mode 1's residue. A box that
    # posted `pending` and then vanished leaves a status the lane waits on
    # forever, and nothing else in the system would ever notice — so a pending
    # status older than a job could possibly still be running is treated as
    # abandoned. Deliberately only PENDING: a `failure` is an answer, and
    # re-running a red PR on a timer would hide a real failure behind an
    # eventually-green flake.
    def needs_check?(repo, raw, now: Time.now)
      entry = Agent::MergeLane.ci_entry(raw)
      return true if entry.nil?
      # nil is "has not answered yet" for BOTH rollup shapes — a queued Actions
      # CheckRun and a `pending` commit status alike (MergeLane.check_state). Only
      # the second can be one of ours, and `stale_pending?` is what tells them
      # apart: it reads the commit STATUSES, which a CheckRun never appears in, so
      # a repo Actions is still answering for is never stolen from it.
      return false unless Agent::MergeLane.check_state(entry).nil?
      stale_pending?(repo, raw["headRefOid"], now: now)
    end

    def stale_pending?(repo, sha, now: Time.now)
      status = latest_status(repo, sha)
      return false if status.nil?
      age = age_seconds(status["created_at"], now: now)
      !age.nil? && age > STALE_PENDING_SECONDS
    end

    def age_seconds(timestamp, now: Time.now)
      return nil if timestamp.to_s.empty?
      now - Time.parse(timestamp.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # The cold build on the base branch. nil when the tip already carries a
    # recent enough `ci`, which on a repo that merges most days is most of the
    # time — a merge moves the tip, and a tip with no status is a candidate by the
    # same rule the PR path uses.
    def main_candidate(repo, now: Time.now)
      sha = Agent::MergeLane.base_sha(Agent::MergeLane.qualify(repo), DEFAULT_BRANCH)
      return nil if sha.to_s.empty?
      status = latest_status(repo, sha)
      unless status.nil?
        age = age_seconds(status["created_at"], now: now)
        return nil if age.nil? || age <= MAIN_MAX_STATUS_AGE_SECONDS
      end
      Candidate.new(repo: repo, pr: nil, sha: sha, event: "push")
    end

    # What this runner would enqueue right now, capped, enrolled repos only.
    #
    # `dropped` is returned rather than discarded so the caller can LOG it. A cap
    # nobody can see reads as "the fleet is keeping up" when the truth is that
    # 45 PRs are waiting. `included_main` is returned for the same reason the
    # marking is left to the caller: `dev ci scan` must be able to show a human
    # what the fleet would do WITHOUT consuming the fleet's next scan window.
    Scan = Struct.new(:candidates, :dropped, :included_main, keyword_init: true)

    def scan(limit: ENQUEUE_CAP, now: Time.now, include_main: nil)
      include_main = main_due?(now: now) if include_main.nil?
      eligible = repos.flat_map { |repo| pr_candidates(repo, now: now) }
      eligible += repos.filter_map { |repo| main_candidate(repo, now: now) } if include_main
      # Enrolment is asked LAST, so the cheap filters above have already removed
      # every PR that would not be built anyway — and the answer is cached per
      # sha, so a repo that is not enrolled costs one API call per new commit
      # rather than one per scan.
      enrolled = interleave(eligible.select { |c| enrolled?(c.repo, c.sha) })
      Scan.new(candidates: enrolled.first(limit), dropped: [enrolled.length - limit, 0].max,
               included_main: include_main)
    end

    # ROUND-ROBIN ACROSS REPOS, oldest pull request first within each.
    #
    # `open_prs` already returns one repo's pull requests oldest-first, which is
    # the lane's own FIFO order and the right order WITHIN a repo. Concatenating
    # the repos and taking the first N would be the wrong order ACROSS them: one
    # repo with twenty PRs waiting — which is exactly what a merge into it
    # produces, since every merge invalidates every sibling — would take every
    # slot in every pass, and a one-PR repo behind it would never be built at all.
    def interleave(candidates)
      groups = candidates.group_by(&:repo).values
      return [] if groups.empty?
      Array.new(groups.map(&:length).max) { |i| groups.filter_map { |g| g[i] } }.flatten
    end

    def main_due?(now: Time.now, file: Agent::Paths.verify_scan_file)
      last = Agent::Paths.read_json(file)
      at = last && last["main_at"]
      parsed = (Time.parse(at) if at) rescue nil
      parsed.nil? || (now - parsed) >= MAIN_SCAN_INTERVAL_SECONDS
    end

    def mark_main_scanned(now: Time.now, file: Agent::Paths.verify_scan_file)
      previous = Agent::Paths.read_json(file) || {}
      Agent::Paths.write_json(file, previous.merge("main_at" => now.utc.iso8601))
    end

    # ---------------- claiming ----------------

    # THE FLEET-WIDE DEDUP (failure mode 6), and the reason it is a POST rather
    # than a file on this runner: the state has to be visible to the OTHER box.
    #
    # Post `pending` carrying a token only this process knows, then read the
    # context back. GitHub keeps the latest status per context, so exactly one
    # racing box sees its own token and the losers drop the job before spending a
    # build on it. It costs one extra read per enqueue and needs no lease, no
    # registry and no new table.
    #
    # Posting at ENQUEUE rather than at start is also what makes the job visible:
    # the lane reads `:ci_pending` and waits, a human sees "queued on Mac", and
    # the next scan's `needs_check?` sees an answer in flight and does not enqueue
    # it again.
    def claim(candidate, token: SecureRandom.hex(4))
      queued = "queued on #{hostname} (#{token})"
      return nil unless post_status(candidate.repo, candidate.sha, state: "pending", description: queued)
      current = latest_status(candidate.repo, candidate.sha)
      return nil unless current && current["description"].to_s.include?(token)
      token
    end

    # ---------------- job records ----------------
    #
    # The same shape, and the same status, as Agent::Jobs: a CACHE whose only
    # question is "is this pid alive". Delete every one of them and the cost is
    # some `ci` statuses that stay pending until STALE_PENDING_SECONDS re-enqueues
    # them — which is exactly the self-heal the abandoned-pending rule exists for.

    def all
      dir = Agent::Paths.verify_jobs_dir
      return [] unless Dir.exist?(dir)
      Dir.glob(File.join(dir, "*.json")).sort.filter_map { |f| Agent::Paths.read_json(f) }
    end

    def live = all.select { |record| alive?(record["pid"]) }

    def write(record)
      Agent::Paths.write_json(Agent::Paths.verify_job_file(record.fetch("key")), record, mode: 0600)
      record
    end

    def delete(key)
      file = Agent::Paths.verify_job_file(key)
      File.delete(file) if File.exist?(file)
    end

    # POSITIVE pids only, and that guard is not defensive noise. `Process.kill`
    # reads a non-positive argument as a PROCESS GROUP — `kill(0, -1)` signals
    # every process this user owns and returns happily, so a record carrying a
    # junk pid would read as alive forever, and `kill` on the same record would
    # take down the machine.
    def alive?(pid)
      return false unless pid.to_i.positive?
      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM, TypeError
      false
    end

    def timed_out?(record, now: Time.now)
      at = record["timeout_at"]
      return false if at.nil?
      now >= Time.parse(at)
    rescue ArgumentError
      false
    end

    def posted_file(key) = File.join(Agent::Paths.verify_log_dir(key), "posted")
    def result_file(key) = File.join(Agent::Paths.verify_log_dir(key), "result")
    def log_file(key)    = File.join(Agent::Paths.verify_log_dir(key), "build.log")

    def posted(key) = read_marker(posted_file(key))
    def result(key) = read_marker(result_file(key))

    def read_marker(file)
      return nil unless File.file?(file)
      value = File.read(file).strip
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    # TWO MARKERS, WRITTEN EITHER SIDE OF THE POST, and the ordering is the whole
    # crash-safety argument. The reap runs in a different process, minutes later,
    # and can only read what the worker wrote down:
    #
    #   result  BEFORE the post. What the build actually decided. A worker killed
    #           between deciding and posting leaves this, and the reap posts the
    #           TRUE answer rather than inventing one.
    #   posted  AFTER the post. A worker killed between the post and this write
    #           is re-read as "not posted", and the reap re-posts the same state —
    #           idempotent, because GitHub keeps the latest status per context.
    #
    # With neither, the worker vanished before it had an answer at all, and the
    # reap posts `failure` with the infrastructure marker. That direction is
    # chosen deliberately: a PR parked is unparked by a human, while a `pending`
    # nobody will ever replace is a lane that waits forever.
    def mark_result(key, state) = Agent::Paths.write_atomic(result_file(key), "#{state}\n")
    def mark_posted(key, state) = Agent::Paths.write_atomic(posted_file(key), "#{state}\n")

    # ---------------- spawning ----------------

    # Start the job detached and record it, exactly as Agent::Jobs.spawn_session
    # does and for the same reason: this tick exits in seconds and the build runs
    # for minutes. The next tick finds it again from the record.
    #
    # `dev ci verify` rather than an inline call, so the ONE command a human runs
    # to confirm a repo's first build by hand (failure mode 5) is the same command
    # the fleet runs, with the same defaults.
    def spawn(candidate, now: Time.now, dev_bin: Agent::Paths.dev_bin)
      Agent::Paths.mkdir_p(Agent::Paths.verify_log_dir(candidate.key))
      # A previous attempt on this same sha left markers behind, and a stale one
      # would be read by the reap as THIS attempt's answer.
      [posted_file(candidate.key), result_file(candidate.key)].each { |f| File.delete(f) if File.exist?(f) }

      cmd = [dev_bin, "ci", "verify", "--repo", Agent::MergeLane.qualify(candidate.repo),
             "--sha", candidate.sha, "--event", candidate.event.to_s]
      cmd += ["--pr", candidate.pr.to_s] if candidate.pr
      script = "#{Shellwords.join(cmd)} >> #{Shellwords.escape(log_file(candidate.key))} 2>&1"
      pid = Process.spawn("/bin/sh", "-c", script, pgroup: true)
      Process.detach(pid)

      write("key" => candidate.key, "repo" => Agent::MergeLane.qualify(candidate.repo),
            "pr" => candidate.pr, "sha" => candidate.sha, "event" => candidate.event,
            "pid" => pid, "host" => hostname,
            "started_at" => now.utc.iso8601,
            "timeout_at" => (now + JOB_TIMEOUT_SECONDS).utc.iso8601)
      pid
    end

    # SIGTERM then SIGKILL to the job's whole process group. The group is right
    # here where it was wrong for sessions (ISS-782): `spawn` above puts the
    # wrapper in its own group and the build's children — sbt, docker, npm — are
    # ordinary descendants of it rather than processes a CLI re-groups, so the
    # group IS the job.
    def kill(pid, grace: 10)
      return false unless alive?(pid)
      signal_group(pid, "TERM")
      deadline = Time.now + grace
      sleep(0.2) while alive?(pid) && Time.now < deadline
      signal_group(pid, "KILL") if alive?(pid)
      true
    end

    def signal_group(pid, signal)
      Process.kill("-#{signal}", pid.to_i)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill(signal, pid.to_i)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    # ---------------- reaping ----------------

    # What a finished job left behind, and the only place a status is posted on
    # behalf of a worker that did not post its own.
    #
    # Yields `[record, outcome, message]` for the caller to log. Outcomes:
    #   :answered   the worker posted; nothing to do but forget the record
    #   :rescued    the worker died without answering, so the lane was given a
    #               `failure` here rather than left waiting on `:ci_pending`
    #   :unresolved the rescue POST itself failed. The record is KEPT and retried
    #               next tick — dropping it would leave the pending status with
    #               nothing left that knows about it.
    def reap(now: Time.now)
      all.each do |record|
        next if alive?(record["pid"])
        key = record["key"]
        state = posted(key)
        if state
          delete(key)
          yield(record, :answered, "posted #{state}") if block_given?
          next
        end

        # The worker decided but could not post — a `gh` blip, or a kill between
        # the two markers. Re-post ITS answer, never a guess.
        known = result(key)
        rescued = known ? repost(record, known) : rescue_status(record, now: now)
        delete(key) if rescued
        message =
          if !rescued then "could not post the status — retrying next tick"
          elsif known then "worker could not post; re-posted #{known}"
          else "worker exited without answering — posted failure"
          end
        yield(record, rescued ? (known ? :reposted : :rescued) : :unresolved, message) if block_given?
      end
    end

    def repost(record, state)
      posted = post_status(record["repo"], record["sha"], state: state,
                           description: clip("#{state} [#{record['host']}] #{log_file(record['key'])}"))
      mark_posted(record["key"], state) if posted
      posted
    end

    def rescue_status(record, now: Time.now)
      reason = timed_out?(record, now: now) ? "exceeded its #{JOB_TIMEOUT_SECONDS / 60}m deadline" : "exited without answering"
      posted = post_status(record["repo"], record["sha"], state: "failure",
                           description: clip("INFRASTRUCTURE FAULT (worker) on #{record['host']} — #{reason}; " \
                                             "log: #{log_file(record['key'])}"))
      mark_posted(record["key"], "failure") if posted
      posted
    end

    # ---------------- the build itself ----------------

    # Where a repo is checked out to build it. NOT any session's workspace
    # (failure mode 4): a build run in the tree an authoring session is still
    # editing measures something nobody is merging.
    #
    # Persistent per repo, because PRESERVED INCREMENTAL STATE is the entire
    # argument for building on our own hardware — zinc's analysis lives in
    # `target/`, inside the checkout, and a fresh clone per build throws it away.
    # It is the one expensive thing under `state_dir`, and losing it costs a cold
    # build rather than correctness, which keeps "delete ~/.platform and the cost
    # is one re-registration" true in the sense that matters.
    def checkout_dir(repo) = Agent::Paths.ci_checkout(Agent::MergeLane.qualify(repo))

    # Put the checkout at exactly `sha`, and take the tree back to what that
    # commit says it is.
    #
    # `git clean -fd` (WITHOUT `-x`) on the warm path is the precise expression of
    # the false-green rule: it removes untracked files a previous build left, and
    # leaves the IGNORED ones — `target/`, `node_modules/` — which is what makes
    # the build warm. The cold path adds `-x` and takes those too, which is what
    # `main` and anything unlisted get, because stale incremental state is the one
    # failure with no human downstream: it produces a green the lane merges.
    #
    # Returns nil on success, or an operator-facing string naming what failed.
    def checkout(repo, sha, pr: nil, clean: true)
      slug = Agent::MergeLane.qualify(repo)
      dir = checkout_dir(slug)
      unless Dir.exist?(File.join(dir, ".git"))
        Agent::Paths.mkdir_p(File.dirname(dir))
        result = capture(["git", "clone", "--quiet", "https://github.com/#{slug}.git", dir],
                         timeout: GIT_TIMEOUT_SECONDS)
        return "clone failed: #{result.summary}" unless result.ok?
      end

      # A named ref rather than the bare sha: GitHub serves `refs/pull/N/head` and
      # `refs/heads/main` to any client, while fetching a loose commit depends on
      # server configuration this fleet does not control.
      ref = pr ? "+refs/pull/#{pr}/head:refs/ci/pr-#{pr}" : "+refs/heads/#{DEFAULT_BRANCH}:refs/ci/#{DEFAULT_BRANCH}"
      steps = [
        ["git", "-C", dir, "fetch", "--quiet", "--prune", "origin", ref],
        ["git", "-C", dir, "checkout", "--quiet", "--detach", "--force", sha],
        ["git", "-C", dir, "reset", "--quiet", "--hard", sha],
        ["git", "-C", dir, "clean", "-q", clean ? "-xfd" : "-fd"],
      ]
      steps.each do |cmd|
        result = capture(cmd, timeout: GIT_TIMEOUT_SECONDS)
        return "#{cmd[3]} failed: #{result.summary}" unless result.ok?
      end
      nil
    end

    # What this repo's build says it needs from the machine, read out of the
    # script at the sha being built. Unknown names are IGNORED rather than
    # rejected, exactly as `Agent::Ci.preflight` treats them: a script naming a
    # probe a newer `dev` will have should run on today's runner, not fail closed
    # on its own configuration.
    def needs(dir)
      path = File.join(dir, BUILD_SCRIPT)
      return [] unless File.file?(path)
      File.read(path).lines.each do |line|
        match = NEEDS_DIRECTIVE.match(line)
        next unless match
        return match[1].split(",").map(&:strip).reject(&:empty?)
      end
      []
    rescue StandardError
      []
    end

    # The environment the build script runs under.
    #
    # PATH is prepended with THIS devops checkout's bin, never left to whatever is
    # on the machine's PATH, for the reason Agent::Paths gives about `dev_bin`:
    # the tick fast-forwards this checkout on every Phase A and then runs out of
    # it, so a build that resolved `claude-db` somewhere else would be running
    # code nothing here updates.
    #
    # `CLAUDE_SESSION_ID` is set HERE rather than by the spawner so that a human
    # running `dev ci verify` by hand — which is how a repo's first build is
    # confirmed — gets the same isolated database the fleet does, instead of the
    # ~/code/ai fallback or a hard failure.
    #
    # `SBT_OPTS` is the same idea for the heap (ISS-753): the build script says
    # `sbt test` and never a number, so the ceiling is this machine's own — a
    # share of RAM sized against how many slots it runs — rather than a constant
    # that was wrong on both fleet machines. Unlike a session, a build script is
    # spawned directly and NOT through a login shell, so this value is the one
    # that reaches sbt: it beats the inherited `~/.zprofile` value the tick
    # itself was started with.
    def build_env(repo:, sha:, pr:, event:, clean:, now: Time.now)
      {
        "CI" => "true",
        "CI_REPO" => Agent::MergeLane.qualify(repo),
        "CI_SHA" => sha.to_s,
        "CI_PR" => pr.to_s,
        "CI_EVENT" => event.to_s,
        "CI_CLEAN_BUILD" => clean.to_s,
        "CLAUDE_SESSION_ID" => session_id(repo, sha, now: now),
        "SBT_OPTS" => Agent::Heap.sbt_opts,
        "PATH" => "#{File.join(Agent::Paths.devops_repo, 'bin')}:#{ENV.fetch('PATH', '')}",
      }
    end

    # Run the build, streaming its output to whatever this process's stdout is —
    # which under `spawn` above is the job log. Streamed rather than captured
    # because a build log nobody can watch while it runs is a build log nobody
    # uses, and because a suite that writes more than a pipe buffer must not
    # block on a reader that is not there.
    #
    # Returns `[:ok, status]`, `[:timed_out, nil]`, or `[:missing, nil]`.
    def build(dir, env:, timeout: BUILD_TIMEOUT_SECONDS, poll: 1)
      path = File.join(dir, BUILD_SCRIPT)
      return [:missing, nil] unless File.file?(path)

      # The shebang when the file is executable, `/bin/bash` when it is not. A
      # script landed without its exec bit is a mistake that would otherwise park
      # every PR in the repo, and running it is strictly better than refusing it.
      cmd = File.executable?(path) ? [path] : ["/bin/bash", path]
      pid = Process.spawn(env, *cmd, chdir: dir, pgroup: true)
      deadline = Time.now + timeout
      loop do
        done, status = Process.waitpid2(pid, Process::WNOHANG)
        return [:ok, status] if done
        if Time.now >= deadline
          kill(pid)
          Process.waitpid(pid) rescue nil
          return [:timed_out, nil]
        end
        sleep(poll)
      end
    end

    # ---------------- the whole job, end to end ----------------

    # `state` is what goes on the commit, `exit_code` is what the process leaves.
    # They are separate because a build that FAILED and a runner that could not
    # ANSWER both park the PR, and only the second one means "fix the machine".
    Outcome = Struct.new(:state, :stage, :description, :exit_code, keyword_init: true) do
      def infra? = stage != :build
      def ok? = state == "success"
    end

    # THE JOB. One entry point, used identically by the tick and by a human
    # confirming a repo's first build by hand (failure mode 5) — because a
    # rollout step that is a different code path from the thing being rolled out
    # proves nothing about it.
    #
    # EVERY PATH OUT OF HERE POSTS A TERMINAL STATUS. That is not tidiness: the
    # lane reads `:ci_pending` for a job still running and for a job that died,
    # and waits forever on both, so silence is the one outcome nothing recovers
    # from. A checkout that failed, a preflight fault, a build that hung — each
    # posts, and each says in the description whether the machine or the branch
    # is what needs looking at.
    def perform(repo:, sha:, pr: nil, event: "pull_request", post: true,
                now: Time.now, out: $stdout, timeout: BUILD_TIMEOUT_SECONDS)
      slug = Agent::MergeLane.qualify(repo)
      clean = Agent::Ci.clean_build?(event: event)
      started = Time.now
      out.puts("verify #{slug}#{pr ? "##{pr}" : ''} @ #{sha} (#{event}, #{clean ? 'cold' : 'warm'}) on #{hostname}")

      fault = checkout(slug, sha, pr: pr, clean: clean)
      return settle(slug, sha, infra(:checkout, fault), post: post, out: out) if fault

      dir = checkout_dir(slug)
      wanted = needs(dir)
      report = Agent::Ci.preflight(needs: wanted, now: now)
      report.checks.each { |c| out.puts("  #{c.ok? ? 'ok   ' : 'FAULT'} #{c.name.ljust(9)} #{c.detail}") }
      unless report.ok?
        remedy = report.faults.map { |c| "#{c.name}: #{c.detail} — fix: #{c.remedy}" }.join("; ")
        out.puts("CI INFRASTRUCTURE FAULT (preflight): #{remedy}")
        return settle(slug, sha, infra(:preflight, report.summary), post: post, out: out)
      end

      env = build_env(repo: slug, sha: sha, pr: pr, event: event, clean: clean, now: now)
      out.puts("running #{BUILD_SCRIPT} (session #{env['CLAUDE_SESSION_ID']})")
      result, status = build(dir, env: env, timeout: timeout)
      settle(slug, sha, outcome_for(result, status, started: started, timeout: timeout), post: post, out: out)
    end

    def outcome_for(result, status, started:, timeout:)
      elapsed = "#{((Time.now - started) / 60).round(1)}m"
      case result
      when :missing
        infra(:script, "#{BUILD_SCRIPT} is missing from the checkout, so this repo is not enrolled after all")
      when :timed_out
        infra(:timeout, "the build exceeded its #{timeout / 60}m deadline and was killed")
      else
        code = status&.exitstatus
        # 75 is the build script saying "this is the machine, not the branch"
        # (Agent::Ci::INFRA_EXIT_CODE). Believed HERE, where it changes what a
        # person does, and deliberately not taught to the lane — which parks the
        # PR either way, and should not take a machine's word about itself.
        return infra(:machine, "the build reported an infrastructure fault (exit #{code}) after #{elapsed}", exit_code: code) if code == Agent::Ci::INFRA_EXIT_CODE
        return Outcome.new(state: "success", stage: :build, description: "passed in #{elapsed}", exit_code: 0) if code&.zero?
        Outcome.new(state: "failure", stage: :build,
                    description: "the suite failed (exit #{code.nil? ? 'unknown' : code}) after #{elapsed}",
                    exit_code: code || 1)
      end
    end

    def infra(stage, detail, exit_code: Agent::Ci::INFRA_EXIT_CODE)
      Outcome.new(state: "failure", stage: stage,
                  description: "INFRASTRUCTURE FAULT (#{stage}) — #{detail}",
                  exit_code: exit_code || Agent::Ci::INFRA_EXIT_CODE)
    end

    # Post, then record having posted — see `mark_posted` for why that order and
    # not the other one.
    def settle(repo, sha, outcome, post:, out:)
      line = "#{outcome.state}: #{outcome.description}"
      out.puts(line)
      out.puts("log: #{log_file(key(repo, sha))}")
      return outcome unless post

      mark_result(key(repo, sha), outcome.state)
      described = clip("#{outcome.description} [#{hostname}] #{log_file(key(repo, sha))}")
      if post_status(repo, sha, state: outcome.state, description: described)
        mark_posted(key(repo, sha), outcome.state)
      else
        # The build has an answer and GitHub would not take it. Say so loudly and
        # leave the record UNMARKED: the tick's reap is what notices a job that
        # never answered, and it retries the post from there rather than letting
        # the lane sit on a `pending` nobody will ever replace.
        out.puts("could not post the `#{CHECK}` status to #{repo}@#{short(sha)} — the reap will retry it")
      end
      outcome
    end
  end
end
