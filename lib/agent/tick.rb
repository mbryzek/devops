require 'open3'
require 'time'
require 'agent/api'
require 'agent/checkout'
require 'agent/gc'
require 'agent/github'
require 'agent/host'
require 'agent/jobs'
require 'agent/notify'
require 'agent/outcome'
require 'agent/paths'
require 'agent/producers'
require 'agent/prompt'
require 'agent/workspace'

# `dev agent tick` — one shot, run by launchd every 30 seconds. THERE IS NO
# DAEMON: no slot manager, no supervision loop, no restart semantics, no partial
# state to recover. All durable state is on the platform and the only local
# state is "is this pid alive", so a tick that dies halfway costs 30 seconds.
#
# TWO PHASES, TWO LOCKS, and the split is the point (design §4.3).
#
#   Phase A — vitals. Always runs, never blocked by Phase B.
#   Phase B — work (reap, producers, claim). Skipped entirely if a previous tick
#             still holds the lock.
#
# Putting both under one lock inverts the system's own alarm. A slow Phase B — a
# large clone, a hung `gh` — would block every subsequent tick, so heartbeats
# would stop while the machine is perfectly healthy: three hours of that trips
# `agent_runner_heartbeat_stale` and reports an outage that is not happening.
# Worse, LEASE heartbeats would stop too, so `expire_issue_leases` would pull
# issues back to `open` and requeue work that is still actively running — the
# machine would compete with itself.
#
# Phase A is bounded and idempotent by construction: a few HTTP calls and
# `kill -0` checks. No cloning, no spawning. Two concurrent Phase A runs are
# harmless, because extending a lease twice extends it once.
#
# Locking is Ruby's File#flock, NOT the flock(1) command: that utility ships with
# util-linux and is present in neither macOS's base system nor homebrew. A plist
# wrapping the tick in `/usr/bin/flock -n` would fail with "command not found" on
# every fire, and because launchd only records a non-zero exit the dispatcher
# would be dead on arrival with no obvious symptom.
module Agent
  class Tick
    # 10-minute heartbeats against the platform's 3-hour staleness window is an
    # 18x margin — enough to absorb a reboot, a FileVault unlock, and a brief
    # network outage without flapping. The window itself is NOT duplicated here:
    # the server sets `is_stale` from the same predicate the invariant uses.
    RUNNER_HEARTBEAT_SECONDS = 10 * 60

    # Non-terminal issue statuses, for the producer in-flight check. Kept as the
    # complement of TERMINAL_ISSUE_STATUSES so adding a status to the spec cannot
    # silently make a producer re-file over live work.
    NON_TERMINAL_STATUSES = %w[open claimed needs_review needs_input fixed deployed].freeze

    attr_reader :decisions

    def initialize(use_localhost:, claude_argv:, dry_run: false, now: Time.now, verbose: false)
      @use_localhost = use_localhost
      @claude_argv = claude_argv
      @dry_run = dry_run
      @now = now
      @verbose = verbose || dry_run
      @decisions = []
    end

    def run
      log("tick start#{@dry_run ? ' (dry run — no side effects)' : ''}")
      phase_a
      with_lock(Agent::Paths.work_lock) do |acquired|
        if acquired
          phase_b
        else
          log("work phase busy — a previous tick still holds the lock; vitals only")
        end
      end
      log("tick done")
      @decisions
    end

    # ---------------- Phase A: vitals ----------------

    def phase_a
      # FIRST, and deliberately before anything that touches the platform: this
      # is the one thing in the tick that works with the platform down, and the
      # sha it lands on is what the registry report below claims.
      update_checkout
      identity = ensure_identity
      heartbeat_runner(identity) if identity
      heartbeat_leases(identity)
      report_registry(identity) if identity
    rescue SessionExpired, ApiError => e
      # Vitals must not abort the tick: the hard-timeout enforcement below is
      # precisely what has to keep working when the platform is unreachable.
      log("vitals: platform error (#{e.message})")
      enforce_timeouts
    end

    # One push to devops reaches the whole fleet: rather than logging into every
    # machine to pull, the tick pulls its own checkout. See Agent::Checkout for
    # why this is --ff-only, why it reports instead of raising, and why Phase A
    # (never mid-job, never behind the work lock) is the only safe place for it.
    #
    # The pull takes effect NEXT tick. `dev agent tick` is one shot, so the
    # process now running has already loaded every file it will use; new code
    # runs when launchd fires again 30 seconds later.
    def update_checkout
      return log("would pull #{Agent::Checkout.devops_repo} (--ff-only origin main)") if @dry_run

      # Under the vitals lock so two overlapping ticks cannot run `git pull` in
      # the same working tree and collide on index.lock.
      with_lock(Agent::Paths.vitals_lock) do |acquired|
        next unless acquired
        result = Agent::Checkout.pull
        if result.ok?
          log("devops checkout: #{result.message}") if result.changed?
        else
          # NEVER fatal. A machine that cannot pull keeps running the code it
          # has; the sha it reports is what makes that visible in admin rather
          # than leaving it silently stale.
          decide("checkout", "devops pull failed (#{result.message}) — staying on #{Agent::Checkout.short(Agent::Checkout.head_sha)}")
        end
      end
    end

    # What this machine reads producers.yml to be: every producer, its cadence,
    # and the next-due moment THIS runner computed, plus the devops sha it all
    # came from.
    #
    # Reported state, not a definition. The server still never evaluates a
    # schedule — but run history alone cannot show "should have run and did
    # not", because a dead producer and a quiet one are the same silence, and a
    # producer nobody schedules anymore leaves no rows at all. Comparing reports
    # across machines is also the only way sha skew is visible: no single runner
    # can see that it is the one on the old checkout.
    #
    # Rate: on a devops sha change (so a push shows up the tick after it lands),
    # otherwise on the heartbeat cadence — next_due_at moves every time a
    # producer runs, so a sha-only trigger would leave it stale for days.
    def report_registry(identity)
      sha = Agent::Checkout.head_sha
      return log("registry: #{Agent::Checkout.devops_repo} is not a git checkout — not reporting") if sha.nil?
      return unless registry_report_due?(sha)

      registry = Agent::Producers.load
      producers = Agent::Producers.report(registry, last_run_by_key: last_run_by_key(identity), now: @now)
      if @dry_run
        log("would PUT /agent/registry/#{identity.runner_id} (#{producers.length} producers @ #{Agent::Checkout.short(sha)})")
        return
      end

      Agent::Api.report_registry(identity.runner_id, devops_sha: sha, producers: producers,
                                 token: identity.token, use_localhost: @use_localhost)
      Agent::Paths.write_json(Agent::Paths.registry_report_file,
                              { "devops_sha" => sha, "at" => @now.utc.iso8601 }, mode: 0600)
      log("registry reported: #{producers.length} producers @ #{Agent::Checkout.short(sha)}")
    rescue Agent::Producers::ConfigError => e
      # A registry this machine cannot parse is a real problem, but it is the
      # producer path's problem to report — it must not cost the machine its
      # heartbeat.
      log("registry: #{e.message}")
    end

    def registry_report_due?(sha)
      last = Agent::Paths.read_json(Agent::Paths.registry_report_file)
      return true if last.nil? || last["devops_sha"] != sha
      at = Time.parse(last["at"].to_s) rescue nil
      at.nil? || (@now - at) >= RUNNER_HEARTBEAT_SECONDS
    end

    def ensure_identity
      cached = Agent::Host.cached_identity
      return cached if cached
      if @dry_run
        log("would self-register this machine (no ~/.platform/agent.identity yet)")
        return nil
      end
      identity, runner = Agent::Host.identity(use_localhost: @use_localhost)
      log("registered runner #{identity.runner_id} (max_concurrency #{runner && runner['max_concurrency']})")
      identity
    end

    # Unconditional: it fires when paused, idle, fully busy, and when Phase B is
    # skipped. It reports on the MACHINE, not the work. A claim call cannot serve
    # this purpose — a paused or idle runner makes no claims, and "no claims" is
    # exactly what a dead machine looks like too.
    # Phase A's own short lock, held across the read-POST-write so the throttle
    # file actually throttles. It guards nothing else — two concurrent Phase A
    # runs are harmless in every other respect, since extending a lease twice
    # extends it once.
    def heartbeat_runner(identity)
      with_lock(Agent::Paths.vitals_lock) do |acquired|
        next unless acquired
        next unless heartbeat_due?
        next log("would POST /agent/runners/#{identity.runner_id}/heartbeat") if @dry_run
        Agent::Api.runner_heartbeat(identity.runner_id, token: identity.token, use_localhost: @use_localhost)
        Agent::Paths.write_atomic(Agent::Paths.heartbeat_file, "#{@now.utc.iso8601}\n", mode: 0600)
        log("runner heartbeat sent")
      end
    end

    def heartbeat_due?
      file = Agent::Paths.heartbeat_file
      return true unless File.file?(file)
      last = Time.parse(File.read(file).strip) rescue nil
      last.nil? || (@now - last) >= RUNNER_HEARTBEAT_SECONDS
    end

    def heartbeat_leases(identity)
      Agent::Jobs.all.each do |record|
        pid = record["pid"]
        next unless Agent::Jobs.alive?(pid)
        next if kill_if_timed_out(record)
        next if identity.nil?
        if @dry_run
          log("would heartbeat lease #{record['lease_id']} for ISS-#{record['issue']}")
          next
        end
        begin
          Agent::Api.heartbeat_lease(record["lease_id"], token: identity.token, use_localhost: @use_localhost)
        rescue ApiError => e
          raise unless e.code == 409
          # The lease expired or was reassigned. Another machine may already be
          # working this issue, so this process must die rather than race it.
          decide("lease_lost", "ISS-#{record['issue']} lease #{record['lease_id']} is gone (409) — killing pid #{pid}")
          Agent::Jobs.mark_killed(record, reason: "lease_lost", now: @now)
          Agent::Jobs.kill(pid)
        end
      end
    end

    # The hard timeout, enforced with no platform involved. An API outage must
    # never be able to produce an immortal job, so this runs on the vitals path
    # AND again on the error path when the platform is unreachable.
    def enforce_timeouts
      Agent::Jobs.all.each do |record|
        next unless Agent::Jobs.alive?(record["pid"])
        kill_if_timed_out(record)
      end
    end

    def kill_if_timed_out(record)
      return false unless Agent::Jobs.timed_out?(record, now: @now)
      decide("timeout", "ISS-#{record['issue']} exceeded its #{Agent::Jobs::TIMEOUT_SECONDS / 3600}h hard timeout — killing pid #{record['pid']}")
      unless @dry_run
        Agent::Jobs.mark_killed(record, reason: "timeout", now: @now)
        Agent::Jobs.kill(record["pid"])
      end
      true
    end

    # ---------------- Phase B: work ----------------

    def phase_b
      identity = Agent::Host.cached_identity
      if identity.nil?
        log("no runner identity yet — skipping work phase")
        return
      end
      reap(identity)
      runner = self_runner(identity)
      run_producers(identity)
      claim(identity, runner)
    rescue SessionExpired, ApiError => e
      log("work phase: platform error (#{e.message})")
    end

    def self_runner(identity)
      runners = Agent::Api.runners(token: identity.token, use_localhost: @use_localhost)
      notify_offline_runners(runners, identity)
      runners.find { |r| r["id"] == identity.runner_id }
    rescue ApiError => e
      log("could not read the fleet (#{e.message}) — assuming this runner is unchanged")
      nil
    end

    # The single most important alert in the system: a machine that reboots and
    # never logs back in looks exactly like an empty queue.
    #
    # `is_stale` comes from the server, which evaluates the SAME predicate as the
    # `agent_runner_heartbeat_stale` invariant and the 15-minute health task.
    # Recomputing it here from `last_heartbeat_at` would be a fourth copy of one
    # threshold, and the CLI and the invariant would eventually disagree about
    # what "offline" means.
    def notify_offline_runners(runners, identity)
      runners.each do |runner|
        next if runner["id"] == identity.runner_id
        next unless runner["is_stale"]
        Agent::Notify.once("runner_offline", runner["id"], now: @now) do
          Agent::Notify.event("dev-agent: runner #{runner['hostname'] || runner['id']} has not checked in since #{runner['last_heartbeat_at']}")
        end
      end
    end

    # ---- reap ----

    def reap(identity)
      Agent::Jobs.all.each do |record|
        next if Agent::Jobs.alive?(record["pid"])
        reap_one(record, identity)
      end
    end

    def reap_one(record, identity)
      number = record.fetch("issue")
      branch = record.fetch("branch")
      workspace = Agent::Workspace.path(record.fetch("slug"))
      started = Time.parse(record.fetch("started_at"))

      # Two lookups, not one, and the reason is ISS-365: the branch is only the
      # branch the executor ASSIGNED, and a session that named its own branch
      # instead is invisible to it. The `ISS-<n>: ` title prefix is the second,
      # independent handle on the same PR — it was already proven as
      # `dev issues reconcile`'s backstop, so the reap uses it directly rather
      # than misclassifying now and being corrected hours later.
      pr = Agent::Github.find_pr_in_workspace(workspace, branch, number) ||
           Agent::Github.search_pr(branch, number)
      plans = Agent::Github.plans_committed_since?(started)
      attempt = lease_attempts(number, identity)

      result = Agent::Outcome.classify(
        pr: pr,
        plans_committed: plans,
        exit_code: Agent::Jobs.exit_code(number),
        producer_filed: record["producer_filed"],
        attempt: attempt,
        timed_out: Agent::Jobs.timed_out?(record, now: @now),
        killed: record["killed"],
      )
      decide("reap", "ISS-#{number} → #{result.name} (issue #{result.status}): #{result.reason}")
      return if @dry_run

      apply_outcome(number, record, result, identity)
      Agent::Jobs.finish(record, { "name" => result.name, "status" => result.status, "reason" => result.reason, "url" => result.url })
      cleanup(record, result)
    end

    def lease_attempts(number, identity)
      Agent::Api.issue_lease_history(number, token: identity.token, use_localhost: @use_localhost).length
    rescue ApiError
      1
    end

    # Never override a status the SESSION already set. `needs_input` is the one
    # outcome a session declares for itself (§4.4), and a session that closed its
    # own issue out with `dev issues status --status fixed` has already reported
    # a truer answer than a re-classification would.
    def apply_outcome(number, record, result, identity)
      hostname = `hostname`.strip rescue "unknown"
      comment = "#{result.name} by #{hostname} — #{result.reason}"

      issue = begin
        Agent::Api.issue(number, use_localhost: @use_localhost)
      rescue ApiError
        nil
      end
      if issue && issue["status"] != "claimed"
        Agent::Api.comment(number, "Session ended; issue already at `#{issue['status']}`. #{comment}", use_localhost: @use_localhost)
      else
        Agent::Api.set_status(number, result.status, comment: comment, url: result.url, use_localhost: @use_localhost)
      end

      release_lease(record, identity)
      notify_outcome(number, result)
    end

    def release_lease(record, identity)
      Agent::Api.release_lease(record["lease_id"], token: identity.token, use_localhost: @use_localhost)
    rescue ApiError => e
      log("could not release lease #{record['lease_id']} (#{e.message}) — it will expire on its own")
    end

    def notify_outcome(number, result)
      case result.name
      when "ready_pr"
        Agent::Notify.event("dev-agent: ISS-#{number} ready for review — #{result.url}")
      when "merged_pr"
        Agent::Notify.event("dev-agent: ISS-#{number} fixed by an already-merged PR — #{result.url}")
      when "gave_up"
        Agent::Notify.event("dev-agent: ISS-#{number} gave up after #{Agent::Outcome::MAX_ATTEMPTS} attempts — needs input")
      end
    end

    def cleanup(record, result)
      # Session databases outlive a dead process. `gc` (not `end`) is the right
      # primitive here: `end` drops the CALLING session's database, and the
      # session that created it is exactly the process that just died. `gc` drops
      # session databases with no active backend and always preserves live ones.
      system("claude-db", "gc", out: File::NULL, err: File::NULL)
      return unless Agent::Outcome.success?(result)
      Agent::Workspace.delete(record.fetch("slug"))
    end

    # ---- producers ----

    def run_producers(identity)
      registry = Agent::Producers.load
      last = last_run_by_key(identity)
      due = Agent::Producers.due(registry, last_run_by_key: last, now: @now)
      if due.empty?
        log("producers: none due")
        return
      end
      timezone = registry.fetch(:timezone)
      due.each do |producer|
        # The guard is the START OF THE CURRENT PERIOD, never the previous run's
        # own start time — see Agent::Schedule.period_start for why that
        # distinction is the difference between a working producer and a
        # permanently wedged one.
        period_start = Agent::Schedule.period_start(producer.schedule, last_run_at: last[producer.key],
                                                    now: @now, timezone: timezone)
        run_producer(producer, period_start, identity)
      end
    rescue Agent::Producers::ConfigError => e
      log("producers: #{e.message}")
    end

    def last_run_by_key(identity)
      runs = Agent::Api.producer_runs(token: identity.token, use_localhost: @use_localhost)
      runs.each_with_object({}) do |run, acc|
        at = Time.parse(run["started_at"]) rescue nil
        next if at.nil?
        key = run["producer_key"]
        acc[key] = at if acc[key].nil? || acc[key] < at
      end
    end

    def run_producer(producer, period_start, identity)
      if @dry_run
        decide("producer", "#{producer.key} is due (#{Agent::Schedule.describe(producer.schedule)}) — would start a run and #{producer.check ? "run: #{producer.check}" : 'file unconditionally'}")
        return
      end

      run = Agent::Api.start_producer_run(producer.key, runner_id: identity.runner_id,
                                          if_no_run_since: period_start,
                                          token: identity.token, use_localhost: @use_localhost)
      if run.nil?
        # An absent `run` in the wrapper has TWO causes: a run is in flight, or
        # one already finished within this period. A compare-and-set, not a
        # scheduler — and the check must NOT run either way, or two machines
        # would both do the work the arbitration exists to deduplicate.
        #
        # The message names both, because it cannot tell them apart from here and
        # asserting the wrong one sends an investigation in the wrong direction:
        # this said "another runner already started this run" for 19 consecutive
        # ticks on a fleet that had exactly one runner and nothing in flight.
        decide("producer", "#{producer.key}: a run for this period is already in flight or finished — skipping")
        return
      end

      started = Time.now
      result, issue_number = execute_producer(producer)
      Agent::Api.finish_producer_run(run.fetch("id"), result: result, issue_number: issue_number,
                                     token: identity.token, use_localhost: @use_localhost)
      line = "#{@now.utc.iso8601} #{producer.key} #{result}#{issue_number ? " ISS-#{issue_number}" : ''} #{(Time.now - started).round(1)}s"
      Agent::Paths.append_log(Agent::Paths.producers_log(@now), line)
      decide("producer", "#{producer.key} → #{result}#{issue_number ? " (ISS-#{issue_number})" : ''}")
    end

    # A producer is a CHEAP CHECK, never the work itself, and it never spawns
    # Claude. The check's stdout becomes the issue body, which is exactly what is
    # wanted for `dev invariants`: the failure list IS the brief.
    #
    # Exit code convention, and the reason `check_failed` can stay distinct from
    # `filed`: 0 = clean, 1 = findings, anything else = the check itself broke.
    # Without a rule like this a crashing producer becomes a nightly stream of
    # bogus issues, which is the fastest way to make the queue untrustworthy.
    def execute_producer(producer)
      output = nil
      if producer.check
        # Through /bin/sh deliberately: checks are written as shell command lines
        # in producers.yml, and a missing binary must come back as exit 127
        # (-> check_failed) rather than raising ENOENT out of the tick.
        output, status = Open3.capture2e({ "LC_ALL" => "en_US.UTF-8" }, "/bin/sh", "-c", producer.check)
        code = status.exitstatus
        return ["check_failed", nil] if code.nil? || code > 1
        return ["nothing_to_do", nil] if code.zero? && producer.file_when != "always"
        return ["nothing_to_do", nil] if producer.file_when == "never"
      end
      return ["nothing_to_do", nil] unless producer.files_issue?

      file_issue(producer, output)
    end

    def file_issue(producer, output)
      existing = Agent::Api.issues(statuses: NON_TERMINAL_STATUSES, use_localhost: @use_localhost)
      return ["skipped_in_flight", nil] if Agent::Producers.in_flight?(existing, producer.fingerprint)

      spec = producer.issue
      # `claim_on_create: false`, not `status: "open"` — the create form has no
      # status field; claiming is expressed as a flag on the insert. A producer
      # never claims: it files for the queue, and the tick's claim path decides
      # who works it.
      form = {
        title: spec.fetch("title"),
        category: spec.fetch("category"),
        fingerprint: spec.fetch("fingerprint"),
        body: producer_body(producer, output),
        claim_on_create: false,
      }
      form[:severity] = spec["severity"] if spec["severity"]
      issue = Agent::Api.create_issue(form, use_localhost: @use_localhost)
      result = issue["occurrence_count"].to_i > 1 ? "recurrence" : "filed"
      [result, issue["number"]]
    end

    def producer_body(producer, output)
      header = "Filed automatically by the `#{producer.key}` producer (devops/agent/producers.yml)."
      body = output.to_s.strip
      evidence =
        if body.empty?
          "#{header}\n\nNo check output — this producer files on a schedule (`#{producer.schedule_text}`)."
        else
          "#{header}\n\n```\n#{producer.check}\n```\n\n#{body}"
        end

      # The playbook goes AFTER the evidence, because the evidence is what this
      # particular run found and the playbook is the standing instruction for
      # every run. A chore with no cheap check carries no evidence at all, and
      # for those the playbook IS the brief — without it the claiming session
      # falls back to the generic default-body triage and does a different job
      # than the one the producer was written to schedule.
      playbook = producer.body_text
      return evidence if playbook.nil? || playbook.empty?
      "#{evidence}\n\n---\n\n#{playbook}"
    end

    # ---- claim ----

    def claim(identity, runner)
      if runner && runner["paused"]
        log("runner is paused — claiming nothing")
        return
      end
      max = (runner && runner["max_concurrency"]) || 1
      live = Agent::Jobs.all.count { |r| Agent::Jobs.alive?(r["pid"]) }
      if live >= max
        log("at capacity (#{live}/#{max}) — claiming nothing")
        return
      end

      (max - live).times do
        if @dry_run
          decide("claim", "would POST /playbook/issue/leases (#{live}/#{max} slots used)")
          break
        end
        lease = begin
          Agent::Api.claim(runner_id: identity.runner_id, token: identity.token, use_localhost: @use_localhost)
        rescue ApiError => e
          break if handle_claim_error(e, identity)
          raise
        end
        # No lease in the response means the queue had nothing claimable — the
        # ordinary idle case, and the ONLY quiet one. The 422 above is not
        # emptiness and never reaches here.
        break if lease.nil?
        start_job(lease, identity)
        live += 1
      end
    end

    # The claim failure that is NOT "no work", handled loudly. Returns true when
    # the caller should stop claiming, false when it should re-raise.
    #
    # Admission control is per-runner concurrency and nothing else — there is no
    # fleet-wide volume cap, so there is no 429 to handle here.
    #
    # 422 — the server does not recognize this runner_id. A client bug, never
    # "nothing to do": most likely the identity cache outlived its row (a runner
    # retired, or a restored/rebuilt platform DB). Silently treating it as an
    # idle queue would leave the machine looking healthy and claiming nothing
    # forever, which is exactly the failure the unconditional heartbeat exists to
    # make visible. So it drops the cached identity — the hardware UUID is the
    # authority, so the next tick re-registers and upserts back onto the same row.
    def handle_claim_error(error, identity)
      case error.code
      when 422
        decide("claim", "REJECTED (422): the platform does not recognize runner #{identity.runner_id} — " \
                        "clearing #{Agent::Paths.identity_file} so the next tick re-registers on this machine's hardware UUID. #{error.message}")
        File.delete(Agent::Paths.identity_file) if File.exist?(Agent::Paths.identity_file)
        true
      else
        false
      end
    end

    def start_job(lease, identity)
      number = lease.fetch("issue_number")
      issue = Agent::Api.issue(number, use_localhost: @use_localhost)
      comments = Agent::Api.issue_comments(number, use_localhost: @use_localhost)

      # A prior attempt's branch with an OPEN PR is resumed in place, so review
      # feedback and a pre-merge rebase update the same PR rather than opening a
      # second one (§4.4.1). A recorded branch whose PR is closed falls through
      # to a fresh branch — pushing to a branch nobody is reviewing is worse than
      # starting over.
      resume_branch = lease["branch"]
      slug = resume_branch && !resume_branch.empty? ? resume_branch : Agent::Workspace.slug(number)
      resume_repo = resume_branch && !resume_branch.empty? ? Agent::Workspace.resume(slug, resume_branch) : nil
      slug = Agent::Workspace.slug(number) if resume_branch && resume_repo.nil?
      workspace = Agent::Workspace.create(slug)

      prompt = Agent::Prompt.build(issue: issue, comments: comments, slug: slug,
                                   workspace: workspace, resume_repo: resume_repo)
      pid = Agent::Jobs.spawn_session(argv: @claude_argv, prompt: prompt, workspace: workspace,
                                      number: number, env: child_env)
      Agent::Jobs.write(
        "issue" => number,
        "pid" => pid,
        "slug" => slug,
        "branch" => slug,
        "lease_id" => lease.fetch("id"),
        "runner_id" => identity.runner_id,
        "resume_repo" => resume_repo,
        "producer_filed" => !issue["fingerprint"].to_s.empty?,
        "started_at" => @now.utc.iso8601,
        "timeout_at" => (@now + Agent::Jobs::TIMEOUT_SECONDS).utc.iso8601,
      )
      hostname = `hostname`.strip rescue "unknown"
      Agent::Api.comment(number, "Claimed by #{hostname} (runner #{identity.runner_id}) on branch `#{slug}`.",
                         use_localhost: @use_localhost)
      decide("claim", "ISS-#{number} claimed → #{workspace} (branch #{slug}, pid #{pid})")
    end

    # Enforcement, not advice (§4.6): core.hooksPath is injected through
    # GIT_CONFIG_* so it applies to EVERY git the session runs, in every repo,
    # and the pre-push hook refuses a push to ~/code/claude that touches anything
    # outside plans/. The rest of that repo is instructions every future session
    # loads and obeys, which makes it the one place a prompt-injected session
    # could persist itself. Saying so in the prompt is necessary; it is not
    # sufficient.
    def child_env
      {
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "core.hooksPath",
        "GIT_CONFIG_VALUE_0" => Agent::Paths.githooks_dir,
        "DEV_AGENT_CLAUDE_REPO" => Agent::Paths.claude_repo,
      }
    end

    # ---------------- plumbing ----------------

    # LOCK_NB is what makes this non-blocking: flock returns false immediately
    # rather than waiting, so ticks never pile up. The lock is released when the
    # process exits, INCLUDING on a crash, so a killed tick cannot wedge the
    # queue.
    def with_lock(path)
      Agent::Paths.mkdir_p(File.dirname(path), mode: 0700)
      file = File.open(path, File::CREAT | File::RDWR, 0600)
      acquired = file.flock(File::LOCK_EX | File::LOCK_NB)
      yield acquired
    ensure
      file&.flock(File::LOCK_UN) if acquired
      file&.close
    end

    def decide(kind, message)
      @decisions << [kind, message]
      log("#{kind}: #{message}")
    end

    def log(message)
      line = "#{Time.now.utc.iso8601} #{message}"
      Agent::Paths.append_log(Agent::Paths.tick_log(@now), line)
      puts line if @verbose
    end
  end
end
