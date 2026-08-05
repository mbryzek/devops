require 'open3'
require 'time'
require 'agent/api'
require 'agent/checkout'
require 'agent/errors'
require 'agent/gc'
require 'agent/github'
require 'agent/host'
require 'agent/jobs'
require 'agent/maintenance'
require 'agent/notify'
require 'agent/outcome'
require 'agent/paths'
require 'agent/playbook'
require 'agent/producers'
require 'agent/prompt'
require 'agent/toolchain'
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

    # Agent::Errors source name for a real (non-benign) devops checkout pull
    # failure. Fixed rather than derived so Agent::Errors.count and the
    # escalation below always agree on what they are counting.
    CHECKOUT_PULL_ERROR_SOURCE = "checkout_pull".freeze

    # File an issue the moment consecutive failures for ANY source CROSS this
    # threshold, not on every tick once past it — see `record_failure`.
    #
    # Deliberately not per-source. Agent::Errors already derives the streak by
    # counting a source's entries rather than tracking a counter, so "3 in a row"
    # is source-agnostic by construction; hard-coding it to `checkout_pull` (as
    # it was when ISS-511 introduced it) was the only thing keeping the machine's
    # other recurring failures — its housekeeping chores above all — silent.
    ERROR_ESCALATE_AT = 3

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
          # Clears the streak on every success, including one that only
          # succeeded via the fetch+reset fallback — a recovered pull is not a
          # failure and must not keep counting toward escalation.
          Agent::Errors.clear(CHECKOUT_PULL_ERROR_SOURCE)
        else
          # NEVER fatal. A machine that cannot pull keeps running the code it
          # has; the sha it reports is what makes that visible in admin rather
          # than leaving it silently stale.
          decide("checkout", "devops pull failed (#{result.message}) — staying on #{Agent::Checkout.short(Agent::Checkout.head_sha)}")
          record_checkout_pull_failure(result) unless result.benign?
        end
      end
    end

    # A benign skip (dirty tree, or a branch other than main — see
    # Agent::Checkout) never reaches here: it is Mike's own interactive work in
    # this checkout, not a reportable failure. Only a real failure — the
    # fetch+reset fallback was tried and still failed, or the checkout is
    # broken outright — is worth a durable count and, eventually, an issue.
    def record_checkout_pull_failure(result)
      record_failure(
        CHECKOUT_PULL_ERROR_SOURCE, result.message,
        title: ->(hostname) { "dev-agent: devops checkout pull failing on #{hostname}" },
        explain: "This machine's devops checkout (Agent::Checkout.devops_repo) could not fast-forward from " \
                 "`origin/main`, and the automatic `git fetch` + `git reset --hard origin/main` recovery " \
                 "attempted in Agent::Checkout.pull also failed. The tick keeps running the code it already " \
                 "has, but producer schedule and prompt changes pushed to devops will not reach this machine " \
                 "until the checkout is fixed by hand.",
      )
    end

    # One durable failure for `source`, and an issue the moment its streak
    # crosses ERROR_ESCALATE_AT.
    #
    # `title` and `explain` come from the CALLER rather than from a table keyed
    # by source. A per-source lookup would be a second registry of prose sitting
    # a file away from the code that knows what actually broke, and it drifts the
    # first time a source is added without one; passing them in makes it
    # impossible to record a failure nobody can explain.
    def record_failure(source, message, title:, explain:)
      entries = Agent::Errors.record(source, message, now: @now)
      count = entries.count { |e| e["source"] == source }
      # Only fire exactly on the tick that crosses the threshold. A streak that
      # is already past it must not re-notify or re-file every 30 seconds.
      escalate_failure(source, message, count, title: title, explain: explain) if count == ERROR_ESCALATE_AT
    end

    def escalate_failure(source, message, count, title:, explain:)
      host = hostname
      Agent::Notify.once("agent_error", source, now: @now) do
        push("agent_error", "dev-agent: #{source} has failed #{count} times in a row on #{host} (#{message})")
      end
      return if @dry_run

      Agent::Api.create_issue(
        {
          title: title.call(host),
          category: "bug",
          fingerprint: "#{source}:#{@now.utc.strftime('%Y-%m-%d')}",
          body: "The `#{source}` source has failed #{count} times in a row on #{host}.\n\n" \
                "Last error:\n\n```\n#{message}\n```\n\n#{explain}",
          claim_on_create: false,
        },
        use_localhost: @use_localhost,
      )
    rescue SessionExpired, ApiError => e
      # Escalation must never take down the rest of the phase it runs in — the
      # same reasoning as phase_a's own top-level rescue.
      log("#{source} escalation: could not file an issue (#{e.message})")
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

      # Producers and a sha, and nothing else. The maintenance vitals that briefly
      # rode along here moved to the heartbeat in ISS-528, for the same reason the
      # error log did in ISS-527: they are about the MACHINE, and this report is
      # about one machine's view of a schedule that is about to stop existing.
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
    #
    # It also carries the job census, which is the only path by which the platform learns what this
    # machine is actually RUNNING as opposed to what it was leased, and (ISS-527) this machine's
    # bounded local error log. Sent on a change to EITHER or on the ten-minute floor, whichever
    # comes first.
    #
    # `errors` is gated the same way as the census and for a sharper reason: the ten-minute floor is
    # a rate limit, and an infra failure that sits unreported for up to ten minutes is exactly the
    # failure someone is trying to see. update_checkout runs BEFORE this in phase_a, so a failure
    # recorded this tick is reported by this tick.
    #
    # And (ISS-528) this machine's housekeeping vitals — last_maintenance_at plus its disk headroom.
    # Same noun as the errors and for the same reason: the subject is the MACHINE. They rode the
    # registry report first, which was the wrong home twice over — that noun is deleted at the
    # server-side-scheduling cutover, and a liveness signal that quietly stops having rows is
    # indistinguishable from a healthy fleet, which is the exact failure it exists to catch.
    #
    # They are DELIBERATELY not part of the change test above. Free disk moves on almost every tick,
    # so gating on it would turn a ten-minute heartbeat into a 30-second one for a signal whose
    # threshold is 48 HOURS — the floor is already three orders of magnitude finer than anything
    # that reads these. Measured only once a send is decided, so a skipped heartbeat costs no `df`.
    #
    # Phase A's own short lock, held across the read-POST-write so the throttle
    # file actually throttles. It guards nothing else — two concurrent Phase A
    # runs are harmless in every other respect, since extending a lease twice
    # extends it once.
    def heartbeat_runner(identity)
      with_lock(Agent::Paths.vitals_lock) do |acquired|
        next unless acquired
        jobs = job_census
        errors = Agent::Errors.list
        last = Agent::Paths.read_json(Agent::Paths.heartbeat_file)
        next unless heartbeat_due?(last) || census_changed?(last, jobs) || errors_changed?(last, errors)
        next log("would POST /agent/runners/#{identity.runner_id}/heartbeat (#{jobs.size} job(s), #{errors.size} error(s))") if @dry_run
        Agent::Api.runner_heartbeat(identity.runner_id, jobs: jobs, errors: errors,
                                                        maintenance: Agent::Maintenance.report(now: @now),
                                                        token: identity.token, use_localhost: @use_localhost)
        Agent::Paths.write_json(Agent::Paths.heartbeat_file,
                                { "at" => @now.utc.iso8601, "jobs" => jobs, "errors" => errors }, mode: 0600)
        log("runner heartbeat sent (#{jobs.size} job(s), #{errors.size} error(s))")
      end
    end

    # What this machine is running, as the platform's fleet view will show it. The pid liveness
    # check is the whole point: a lease says the platform handed out work, and only this side knows
    # whether the process doing it still exists. `finished_unreaped` is the window between a session
    # exiting and Phase B classifying it — ordinary and brief, and a machine that sits in it is a
    # wedged reap rather than a busy machine.
    def job_census
      Agent::Jobs.all.map do |record|
        {
          "issue_number" => record["issue"].to_s,
          "state" => Agent::Jobs.alive?(record["pid"]) ? "running" : "finished_unreaped",
          "pid" => record["pid"].to_i,
          "branch" => record["branch"],
          "started_at" => record["started_at"],
        }.compact
      end.sort_by { |job| job["issue_number"] }
    end

    # The ten-minute floor. Its purpose is unchanged — proving the machine is alive when nothing
    # else is happening — but it is now a FLOOR and not the cadence: a census change reports
    # immediately (see census_changed?), so an idle machine stays as cheap as it ever was while a
    # session starting or ending is visible within one tick instead of up to ten minutes later.
    def heartbeat_due?(last)
      at = last && last["at"]
      return true if at.nil?
      parsed = Time.parse(at) rescue nil
      parsed.nil? || (@now - parsed) >= RUNNER_HEARTBEAT_SECONDS
    end

    # Compared against what was actually SENT, not against the previous tick's census: a heartbeat
    # that failed leaves the file unwritten, so the change is still pending and the next tick
    # retries it rather than concluding nothing happened.
    def census_changed?(last, jobs)
      (last && last["jobs"]) != jobs
    end

    # Same comparison, same reasoning, for the error log — and it is what stops the ten-minute floor
    # from becoming a ten-minute delay on bad news. A failure recorded this tick makes the list
    # differ from what was last sent, so the heartbeat fires now rather than at the next window.
    #
    # Recovery forces a send too, and that is deliberate: Agent::Errors.clear on success is the ONLY
    # way a machine says "this stopped failing", and the platform replaces the list wholesale. Not
    # forcing it here would leave a fixed machine showing a stale failure on the fleet board for up
    # to ten minutes.
    #
    # A machine on a checkout that predates the "errors" key wrote a heartbeat file without one; nil
    # != [] there, so the first tick after the upgrade sends once and then settles. That is correct,
    # not a bug: the platform has never been told this machine's error state.
    def errors_changed?(last, errors)
      (last && last["errors"]) != errors
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

    # FIRST, and deliberately before the identity check and everything that
    # touches the platform: housekeeping is the one piece of work in Phase B that
    # must keep happening on a machine the platform has never heard of and on a
    # machine the platform is currently unreachable from. Anything below this
    # line can raise ApiError and abort the phase (see the rescue), and the point
    # of ISS-520 is that a disk does not stop filling while the control plane is
    # down.
    def phase_b
      run_maintenance
      check_toolchain
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

    # ---- maintenance (ISS-520) ----
    #
    # In Phase B rather than Phase A because it is WORK: a full `docker prune`
    # runs for minutes, and Phase A's lock is what the heartbeat and the lease
    # heartbeats sit behind. Holding the vitals lock through a prune would stop
    # the heartbeats of a machine that is perfectly healthy — the exact inversion
    # the two-phase split exists to prevent — while the work lock is already the
    # right home for something slow: the next tick simply skips its work phase,
    # which is what it does today for any long-running producer.
    #
    # No platform call, no lock beyond the work lock this phase already holds,
    # and no producer run: with N runners the daily compare-and-set gave exactly
    # one machine per day the right to delete ITS OWN files, so N-1 machines
    # never collected anything.
    def run_maintenance
      free, = Agent::Maintenance.disk
      trigger = Agent::Maintenance.due(now: @now, free_bytes: free)
      return if trigger.nil?

      if @dry_run
        decide("maintenance", "#{trigger} — would run: #{Agent::Maintenance.plan(trigger, now: @now).join('; ')}")
        return
      end

      result = Agent::Maintenance.run(now: @now, trigger: trigger)
      result.outcomes.each { |outcome| apply_maintenance_outcome(outcome) }
      decide("maintenance", "#{trigger}: #{result.outcomes.map { |o| "#{o.source} #{o.ok ? 'ok' : 'FAILED'}" }.join(', ')}" \
                            " — reclaimed #{result.reclaimed_bytes || 'unknown'} byte(s)")
    end

    # Success CLEARS the source's streak, exactly as a recovered checkout pull
    # does: a chore that just worked has no active streak, whatever it had
    # before. Failure counts toward the shared 3-in-a-row escalation, which is
    # the whole reason ERROR_ESCALATE_AT stopped being checkout-specific.
    def apply_maintenance_outcome(outcome)
      return Agent::Errors.clear(outcome.source) if outcome.ok

      record_failure(
        outcome.source, outcome.message,
        title: ->(host) { "dev-agent: #{outcome.source} failing on #{host}" },
        explain: "`#{outcome.label}` is runner-local housekeeping: it reclaims disk on THIS machine and " \
                 "nothing another runner does frees it. While it keeps failing this machine's disk only " \
                 "fills, and a full disk here does not announce itself — it kills Docker and then surfaces " \
                 "as unrelated spec failures on whatever this box claims next.\n\n" \
                 "Run it by hand on that machine to see the failure directly: `dev agent maintenance --dry-run` " \
                 "for what it would do, then the command above.",
      )
    end

    # ---- toolchain (ISS-531) ----
    #
    # Runner-local, like maintenance and for the same reason: whether THIS box
    # has `depsguard` is a fact about this box, and a fleet-wide daily lock would
    # have checked one machine and left the rest.
    #
    # NOT `record_failure`. That path debounces at ERROR_ESCALATE_AT because a
    # docker prune or a git fetch can fail transiently and a single blip is not
    # worth an issue. A missing binary has no transient mode — it is installed or
    # it is not — so three strikes at a daily cadence would only mean three days
    # of a producer that still cannot run. It files on the first detection
    # instead, and the SERVER's fingerprint dedup is what stops it re-filing: the
    # key carries the machine and the exact set of missing tools, so a partially
    # provisioned box files an accurate second issue and a fully provisioned one
    # files nothing.
    #
    # Before the identity check on purpose. A machine that has not registered yet
    # is the machine most likely to be missing tools, and this is the report that
    # says so.
    def check_toolchain
      return unless Agent::Toolchain.due?(now: @now)

      result = Agent::Toolchain.check(now: @now)
      summary = result.ok? ? "all required tools present" : "MISSING #{result.missing_required.map(&:name).join(', ')}"
      if @dry_run
        decide("toolchain", "#{summary} — would #{result.ok? ? 'record the check' : 'file an issue'}")
        return
      end

      Agent::Toolchain.record(result)
      decide("toolchain", summary)
      return if result.ok?

      file_toolchain_issue(result)
    end

    # Best-effort in the same sense the rest of Phase B's platform calls are: a
    # box that cannot reach the platform has a bigger problem than an unfiled
    # issue, and the marker is already written so the next cadence retries.
    def file_toolchain_issue(result)
      host = hostname
      Agent::Notify.once("toolchain", "#{host}:#{Agent::Toolchain.missing_key(result)}", now: @now) do
        push("toolchain", "dev-agent: #{host} is missing #{result.missing_required.map(&:name).join(', ')} " \
                          "— #{result.blocked_producers.join(', ')} cannot run there")
      end
      Agent::Api.create_issue(
        {
          title: Agent::Toolchain.issue_title(result, host),
          category: "bug",
          fingerprint: Agent::Toolchain.issue_fingerprint(result, host),
          body: Agent::Toolchain.issue_body(result, host),
          claim_on_create: false,
        },
        use_localhost: @use_localhost,
      )
    rescue SessionExpired, ApiError => e
      log("toolchain: could not file an issue (#{e.message})")
    end

    # THE RUNNER-OFFLINE ALERT IS NOT SENT FROM HERE, DELIBERATELY (ISS-535).
    #
    # It used to be: this method read `is_stale` off every OTHER runner in the
    # fleet response and pushed an openclaw event about it. That is the single
    # most important alert in the system — a machine that reboots and never logs
    # back in looks exactly like an empty queue — and a runner-local check is the
    # wrong place for it twice over. An offline machine cannot report itself, so
    # the alert depends on some PEER being awake; a one-runner fleet, or the last
    # machine standing, therefore reports nothing at all. And every push it did
    # make was a no-op anyway, because `openclaw` is not installed on the runners
    # (ISS-535, ISS-531).
    #
    # The platform already owns it, and already delivers it:
    # `CheckAgentRunnerHealthProcessor` is queued every 15 minutes by
    # `PeriodicActor`, alerts on the machine that CROSSES into staleness (once,
    # by construction, with no notified flag), and emails Mike. It reads the same
    # `AgentInvariants.StaleAfterHours` that produced the `is_stale` this code
    # used to consume — so nothing was lost with the copy, and the server sees
    # the machine that went dark whether or not anything else in the fleet is up.
    #
    # Do not re-add a local copy. Add to the processor instead.
    def self_runner(identity)
      runners = Agent::Api.runners(token: identity.token, use_localhost: @use_localhost)
      runners.find { |r| r["id"] == identity.runner_id }
    rescue ApiError => e
      log("could not read the fleet (#{e.message}) — assuming this runner is unchanged")
      nil
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
        push("pr_ready", "dev-agent: ISS-#{number} ready for review — #{result.url}")
      when "merged_pr"
        push("merged_pr", "dev-agent: ISS-#{number} fixed by an already-merged PR — #{result.url}")
      when "gave_up"
        push("gave_up", "dev-agent: ISS-#{number} gave up after #{Agent::Outcome::MAX_ATTEMPTS} attempts — needs input")
      end
    end

    # One push, and a log line for every one that did not arrive (ISS-535).
    #
    # `Agent::Notify.event` returning a bare `false` into a caller that discarded
    # it is what let this fleet run its whole history with no notification
    # channel at all and nothing anywhere saying so. The line names the backstop
    # that carries the fact instead, because the two halves are only useful
    # together: "undelivered" alone reads as lost work, and the backstop alone
    # reads as a healthy channel.
    def push(kind, text)
      outcome = Agent::Notify.event(kind, text)
      log("notify #{kind}: #{Agent::Notify.explain(kind, outcome)}") if Agent::Notify.reportable?(outcome)
      outcome
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
    rescue Agent::Producers::ConfigError, Agent::Playbook::MissingError => e
      # MissingError is all but unreachable — the registry validated every
      # body_file at parse time, moments ago, at the top of this method. It is
      # caught anyway because the alternative is worse than a missing issue:
      # producers run BEFORE claim in Phase B, so an exception escaping here
      # would take the claim path down with it and the machine would stop
      # picking up work for a reason that has nothing to do with the queue.
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
      return file_epic(producer, output, existing) if producer.epic?

      fingerprint = producer.fingerprint_at(@now)
      return ["skipped_in_flight", nil] if Agent::Producers.in_flight?(existing, fingerprint)

      spec = producer.issue
      # `claim_on_create: false`, not `status: "open"` — the create form has no
      # status field; claiming is expressed as a flag on the insert. A producer
      # never claims: it files for the queue, and the tick's claim path decides
      # who works it.
      form = {
        title: spec.fetch("title"),
        category: spec.fetch("category"),
        fingerprint: fingerprint,
        # Attribution the platform stores as a column, not something anyone has
        # to reconstruct by joining agent_producer_runs: recurrence means many
        # runs point at one issue, so "everything this producer filed" cannot be
        # paginated off the run history.
        producer_key: producer.key,
        body: producer_body(producer, output),
        claim_on_create: false,
      }
      form[:severity] = spec["severity"] if spec["severity"]
      issue = Agent::Api.create_issue(form, use_localhost: @use_localhost)
      result = issue["occurrence_count"].to_i > 1 ? "recurrence" : "filed"
      [result, issue["number"]]
    end

    # An epic and one child per name (ISS-397). The children are the units of
    # work — each gets its own lease, its own retry and its own PR — and the
    # epic is the single thing Mike verifies once they have all landed.
    #
    # ORDER MATTERS: the children are filtered BEFORE the epic is created, so a
    # night where every repo still has last night's issue open files nothing at
    # all rather than leaving an empty container in the queue. Filing the epic
    # first and discovering that afterwards is not recoverable — there is no
    # delete, only `dismissed`.
    def file_epic(producer, output, existing)
      children = producer.children.reject { |child| Agent::Producers.in_flight?(existing, child.fingerprint) }
      if children.empty?
        log("#{producer.key}: every child is still in flight — filing nothing")
        return ["skipped_in_flight", nil]
      end
      fingerprint = producer.fingerprint_at(@now)
      return ["skipped_in_flight", nil] if Agent::Producers.in_flight?(existing, fingerprint)

      spec = producer.issue
      epic = Agent::Api.create_issue(
        {
          type: "epic",
          title: spec.fetch("title"),
          category: spec.fetch("category"),
          fingerprint: fingerprint,
          producer_key: producer.key,
          body: epic_body(producer, output, children),
          claim_on_create: false,
        },
        use_localhost: @use_localhost,
      )
      number = epic["number"]

      children.each do |child|
        form = {
          title: child.title,
          category: child.category,
          fingerprint: child.fingerprint,
          # A STRING on the wire: issue_form.parent_number is typed `string`,
          # and an integer here is a 400 the producer would only find at 3:45am.
          parent_number: number.to_s,
          # Stated rather than left to the platform's parent-inheritance: the
          # child's attribution then does not depend on the epic having been
          # resolved, and every issue this producer filed carries the key even if
          # a child is later detached from its epic.
          producer_key: producer.key,
          body: child_body(producer, child),
          claim_on_create: false,
        }
        form[:severity] = child.severity if child.severity
        filed = Agent::Api.create_issue(form, use_localhost: @use_localhost)
        log("#{producer.key}: ISS-#{filed['number']} #{child.name} → epic ISS-#{number}")
      end

      result = epic["occurrence_count"].to_i > 1 ? "recurrence" : "filed"
      [result, number]
    end

    def epic_body(producer, output, children)
      roster = children.map { |child| "- #{child.title}" }.join("\n")
      skipped = producer.children.length - children.length
      note = skipped.zero? ? "" : "\n\n#{skipped} child(ren) were skipped: a previous run's issue for them is still open."
      "#{producer_body(producer, output)}\n\nThis run filed #{children.length} child issue(s):\n\n#{roster}#{note}"
    end

    def child_body(producer, child)
      header = "Filed automatically by the `#{producer.key}` producer (devops/agent/producers.yml) " \
               "as one child of this run's epic."
      pointer = playbook_pointer(child.playbook_path, target: child.name)
      return header if pointer.nil?
      "#{header}\n\n---\n\n#{pointer}"
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

      # The playbook POINTER goes AFTER the evidence, because the evidence is
      # what this particular run found — run-specific, so it stays inline
      # forever — and the playbook is the standing instruction for every run.
      #
      # A pointer rather than the text (ISS-505): the claiming runner reads the
      # procedure from its own devops checkout, so an issue that sits in the
      # queue for four days runs the CURRENT playbook rather than the copy that
      # existed the night it was filed. What stays inline is the abstract, so
      # the issue still reads as something in admin.
      pointer = playbook_pointer(producer.playbook_path)
      return evidence if pointer.nil?
      "#{evidence}\n\n---\n\n#{pointer}"
    end

    # nil when a producer ships no playbook at all. A path that is configured but
    # unreadable HERE cannot be papered over — the registry validated it at parse
    # time, so an exception at this point means the checkout changed under the
    # tick, and filing a pointer nobody can resolve is the ISS-360 failure.
    def playbook_pointer(path, target: nil)
      return nil if path.nil?
      Agent::Playbook.pointer_block(path, target: target)
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

      # THE claim-time resolution (ISS-505). nil for every issue that carries its
      # brief inline — human-written ones, and everything filed before pointers
      # existed — so those are untouched. A pointer that IS present and does not
      # resolve stops the claim dead rather than starting a session that would do
      # generic triage under the issue's title.
      begin
        playbook = Agent::Playbook.resolve_in(issue["body"])
      rescue Agent::Playbook::MissingError => e
        return abandon_unresolvable_playbook(lease, identity, number, e.message)
      end

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
                                   workspace: workspace, resume_repo: resume_repo, playbook: playbook)
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
      Agent::Api.comment(number, claim_comment(identity, slug, playbook), use_localhost: @use_localhost)
      decide("claim", "ISS-#{number} claimed → #{workspace} (branch #{slug}, pid #{pid})" \
                      "#{playbook ? " playbook #{playbook.label}" : ''}")
    end

    # The first timeline comment, and the audit trail ISS-505 turns on: WHICH
    # playbook this run read and at WHICH sha, with a permalink, so the run stays
    # reproducible after the file changes. Written by the runner rather than left
    # to the session, because the runner is the thing that actually did the read.
    #
    # The staleness note is the inversion made visible — see
    # `checkout_staleness_reason`.
    def claim_comment(identity, slug, playbook)
      lines = ["Claimed by #{hostname} (runner #{identity.runner_id}) on branch `#{slug}`."]
      return lines.first if playbook.nil?

      lines << "" << "Playbook: #{playbook.label}" << playbook.permalink
      reason = checkout_staleness_reason
      lines << "" << "⚠️ #{reason}, so the playbook above may be behind `origin/main`." if reason
      lines.join("\n")
    end

    # Why this machine's devops checkout might not be current, or nil when there
    # is no reason to think it isn't.
    #
    # THIS is the inversion ISS-505 names, answered where the answer is cheap. A
    # runner on a stale checkout reads last month's playbook while the issue
    # claims to run the current one, and `agent_reported_registry` surfaces that
    # only by comparing machines after the fact — no single runner can see it is
    # the odd one out. But a runner CAN see, right now, why its own last pull did
    # not land, so it says so on the issue whose playbook it just read.
    #
    # All three causes are covered deliberately, because only the first alarms
    # anywhere else. A failing pull escalates at three in a row (ISS-511); a
    # DIRTY tree or a checkout off `main` is a benign skip that
    # `record_checkout_pull_failure` never counts — correctly, since it means a
    # human is working in that checkout — and on an unattended mini that is a
    # machine which silently stops updating forever with nothing anywhere saying
    # so. Two `git` calls, on the claim path only.
    def checkout_staleness_reason
      streak = Agent::Errors.count(CHECKOUT_PULL_ERROR_SOURCE)
      return "This runner's devops checkout has failed to fast-forward #{streak} time(s) in a row" unless streak.zero?

      repo = Agent::Checkout.devops_repo
      branch = Agent::Checkout.current_branch(repo)
      return "This runner's devops checkout does not answer `git rev-parse`, so the tick cannot pull it" if branch.nil?
      return "This runner's devops checkout is on `#{branch}`, not `main`, so the tick does not pull it" if branch != "main"
      return "This runner's devops checkout has a dirty working tree, so the tick does not pull it" if Agent::Checkout.dirty?(repo)
      nil
    end

    # A configured playbook this runner cannot read is a HARD stop: no session,
    # and the issue goes to `needs_input` for a human.
    #
    # Never a fallback to generic triage — that is precisely ISS-360, where a
    # producer ported without its playbook silently filed issues instead of
    # shipping PRs for a week. And never a plain release either: releasing
    # returns the issue to `open`, the next tick claims it again, and a runner
    # missing the file would spin on it every 30 seconds while looking busy.
    #
    # `set_status` BEFORE `release_lease`, because releasing only reverts an
    # issue that is still exactly `claimed` — so the release cannot clobber the
    # status just written, and the lease still ends up closed either way.
    def abandon_unresolvable_playbook(lease, identity, number, message)
      text = "Claim aborted on #{hostname}: #{message}\n\n" \
             "This issue points at a playbook in devops (`Playbook:` line in the body) and this runner " \
             "could not read it, so no session was started. Running it anyway would mean generic triage " \
             "under this issue's title — the ISS-360 failure the pointer exists to make impossible.\n\n" \
             "Fix the path under `devops/agent/bodies/`, or correct the pointer line on this issue, then " \
             "move it back to `open`."
      push("playbook_unresolved", "dev-agent: ISS-#{number} playbook did not resolve on #{hostname} (#{message})")
      unless @dry_run
        Agent::Api.set_status(number, "needs_input", comment: text, use_localhost: @use_localhost)
        Agent::Api.release_lease(lease.fetch("id"), token: identity.token, use_localhost: @use_localhost)
      end
      decide("claim", "ISS-#{number}: #{message} — no session started, moved to needs_input")
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

    # This machine's name, as it appears in every escalation, claim comment and
    # reap comment. "unknown" rather than an exception: a box whose `hostname`
    # binary is missing still has to be able to say what it did.
    def hostname
      @hostname ||= (`hostname`.strip rescue "unknown")
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
