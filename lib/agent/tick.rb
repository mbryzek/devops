require 'time'
require 'agent/api'
require 'agent/checkout'
require 'agent/ci'
require 'agent/claude_config'
require 'agent/credentials'
require 'agent/dependency'
require 'agent/dependency_wake'
require 'agent/errors'
require 'agent/escalation'
require 'agent/gc'
require 'agent/github'
require 'agent/heap'
require 'agent/host'
require 'agent/jobs'
require 'agent/maintenance'
require 'agent/newrelic_watch'
require 'agent/ops'
require 'agent/outcome'
require 'agent/paths'
require 'agent/playbook'
require 'agent/prompt'
require 'agent/shell'
require 'agent/stream'
require 'agent/toolchain'
require 'agent/usage_limit'
require 'agent/verify'
require 'agent/workspace'

# `dev agent tick` — one shot, run by launchd every 30 seconds. THERE IS NO
# DAEMON: no slot manager, no supervision loop, no restart semantics, no partial
# state to recover. All durable state is on the platform and the only local
# state is "is this pid alive", so a tick that dies halfway costs 30 seconds.
#
# TWO PHASES, TWO LOCKS, and the split is the point (design §4.3).
#
#   Phase A — vitals. Always runs, never blocked by Phase B.
#   Phase B — work (maintenance, reap, claim). Skipped entirely if a previous tick
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

    # Agent::Errors source name for a real (non-benign) devops checkout pull
    # failure. Fixed rather than derived so Agent::Errors.count and the
    # escalation below always agree on what they are counting.
    CHECKOUT_PULL_ERROR_SOURCE = "checkout_pull".freeze

    # Hard deadline for the `claude-db end` that reclaims a dead session's own
    # databases (ISS-740). It talks to Docker, which is the one dependency here
    # that hangs rather than fails, and this runs inside the reap that has to
    # finish for the lease to be released at all. Losing the databases of one
    # session is what the hourly age-based gc is a backstop for; losing the reap
    # has no backstop.
    CLAUDE_DB_END_TIMEOUT_SECONDS = 120

    # Agent::Errors source name for a `~/code/.claude` this machine cannot make
    # resolve on its own — see Agent::ClaudeConfig. Only the states a human has
    # to clear ever reach it; the ordinary "absent, so create it" path is not a
    # failure and records nothing.
    CLAUDE_CONFIG_ERROR_SOURCE = "claude_config".freeze

    # Agent::Errors source name for a claim that raised after its lease was
    # granted, and for a work phase that died on something other than the two
    # platform errors. Separate sources because they are separate blast radii —
    # a crashing claim costs one issue's dispatch, a crashing phase costs the
    # reap and every claim behind it — and the streak that escalates is derived
    # per source.
    CLAIM_ERROR_SOURCE = "claim".freeze

    WORK_PHASE_ERROR_SOURCE = "work_phase".freeze

    # File an issue the moment consecutive failures for ANY source CROSS this
    # threshold, not on every tick once past it — see `record_failure`.
    #
    # Deliberately not per-source. Agent::Errors already derives the streak by
    # counting a source's entries rather than tracking a counter, so "3 in a row"
    # is source-agnostic by construction; hard-coding it to `checkout_pull` (as
    # it was when ISS-511 introduced it) was the only thing keeping the machine's
    # other recurring failures — its housekeeping chores above all — silent.
    #
    # Lives on Agent::Escalation since ISS-763, which is where the recording and
    # the firing both are now that `dev ci preflight` escalates through the same
    # path. Kept here as the name the rest of this file and the suite already
    # use, so there is exactly one number and two ways to spell it.
    #
    # It reads a number Agent::Errors' eviction has to be able to produce, and
    # for two years it could not: that log was capped in TOTAL, so with five
    # sources failing at once no source's count ever reached 3 and this fired on
    # nobody (ISS-742). The cap is per-source now, and
    # Agent::Errors::PER_SOURCE_CAP > ERROR_ESCALATE_AT is asserted by the suite
    # — strictly greater, because a count that SATURATES at the threshold would
    # match this `==` on every tick forever.
    ERROR_ESCALATE_AT = Agent::Escalation::AT

    # An issue waiting on a dependency that has not merged is deferred a day at a
    # time (ISS-649). A day rather than an hour because the thing being waited on
    # is a human merging a PR, and rechecking that every tick would burn a lease
    # and a `gh` call every 30 seconds to learn the same thing.
    #
    # It is the CEILING on the wait rather than the wait itself since ISS-922:
    # Agent::DependencyWake re-asks the same question every few minutes for the
    # issues that are already deferred, so the ordinary case comes back within
    # minutes of the merge and this is what covers the case where GitHub could
    # not be read at all. Nothing about the argument above changed — that sweep
    # is not the every-tick recheck rejected here, because it touches only the
    # 0-3 issues currently parked and holds no lease.
    DEPENDENCY_DEFER_DAYS = 1

    # ...but not forever. On the seventh consecutive deferral the issue goes to
    # `needs_input` instead: a week of daily checks means the PR is not merely
    # unmerged, it is stuck, and a snoozed issue is invisible to both the queue
    # and the daily nudge while it waits.
    #
    # CONSECUTIVE is enforced by Agent::Dependency.defer_attempts, which resets
    # the run at the last wake (ISS-922). Before that it was a running total, and
    # once a deferral can be lifted early — so an issue can go blocked → cleared
    # → dispatched → blocked again on a different PR — a total escalates on
    # somebody else's history.
    DEPENDENCY_DEFER_LIMIT = 7

    # How a prior deferral is recognised on the timeline, which is where the
    # attempt count is kept. Lives on Agent::Dependency since ISS-922, where the
    # sweep that reads it also is; kept here as the name this file and the suite
    # already use, so there is exactly one string and two ways to spell it —
    # the same arrangement ERROR_ESCALATE_AT has with Agent::Escalation.
    DEPENDENCY_DEFER_MARKER = Agent::Dependency::DEFER_MARKER

    # What `self_runner` answers when the fleet read FAILED, as distinct from the
    # nil it answers when the read succeeded and this machine was simply not in
    # the list. A sentinel rather than nil because the two demand opposite
    # responses: not-in-the-list is an unregistered runner, whose claim 422s into
    # `handle_claim_error` and re-registers itself; could-not-read is a machine
    # whose `paused` flag we cannot see, and pausing is a safety control.
    FLEET_UNREADABLE = :fleet_unreadable

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
      ensure_claude_config
      identity = ensure_identity
      # The runner heartbeat is REPORTING and the lease heartbeats are the thing
      # that keeps live work alive, so a failure of the former must never cost
      # the latter. Its own rescue is what makes that ordering safe: one 500 on
      # the registry POST used to abort phase_a outright, and then every running
      # job went a tick without a lease renewal — the "machine competes with
      # itself" failure this module's header exists to prevent, arriving through
      # the path built to prevent it.
      begin
        heartbeat_runner(identity) if identity
      rescue SessionExpired, ApiError => e
        log("vitals: runner heartbeat failed (#{e.message}) — lease heartbeats still follow")
      end
      heartbeat_leases(identity)
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

    # `~/code/.claude`, which is how every Claude Code session on this machine
    # finds the rules, skills and subagents CLAUDE.md tells it to use. See
    # Agent::ClaudeConfig for what was measured to be missing without it.
    #
    # In Phase A next to update_checkout because it is the same kind of thing:
    # the machine's READ SURFACE, made correct before any work is claimed
    # against it. It is cheaper than the pull — a stat and, once in a machine's
    # life, one `symlink(2)` — and it needs no lock, because the only write is
    # guarded against losing a race with a concurrent tick.
    def ensure_claude_config
      return log("would ensure #{Agent::ClaudeConfig.link} -> #{Agent::ClaudeConfig.target}") if @dry_run

      result = Agent::ClaudeConfig.ensure_link
      # Only a CHANGE is worth a decision line. A machine whose link is already
      # right would otherwise say so every 30 seconds forever.
      decide("claude_config", result.message) if result.linked? || !result.ok?
      if result.ok?
        Agent::Errors.clear(CLAUDE_CONFIG_ERROR_SOURCE)
      else
        record_claude_config_failure(result)
      end
    end

    # Reached only by the states the tick cannot fix for itself: something else
    # already occupies the path, there is no claude checkout to point at, or the
    # symlink call failed outright. Never by the ordinary absent-then-created
    # path, which is a success.
    def record_claude_config_failure(result)
      record_failure(
        CLAUDE_CONFIG_ERROR_SOURCE, result.message,
        title: ->(hostname) { "dev-agent: #{hostname} has no usable ~/code/.claude" },
        explain: "Claude Code finds a project's rules, skills and subagents by looking for a `.claude` " \
                 "directory in the cwd and its ancestors. `#{Agent::ClaudeConfig.link}` is how every " \
                 "session on this machine reaches the `claude` repo, and CLAUDE.md — which every session " \
                 "loads — names paths under it more than a dozen times.\n\n" \
                 "Until it resolves, sessions here silently get NONE of it: no `.claude/rules/*.mdc`, and " \
                 "none of the skills CLAUDE.md instructs them to use by name (`repo-map`, `session-db`, " \
                 "`releasing-libraries`, `writing-as-mike`, `context-handoff`). Nothing errors — a skill " \
                 "that is not there is not a failure a session can see (ISS-615).\n\n" \
                 "Fix: #{result.remedy}",
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
      Agent::Escalation.record(
        source, message, title: title, explain: explain, host: hostname, now: @now,
        dry_run: @dry_run, use_localhost: @use_localhost,
        log: method(:log),
      )
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
    # And (ISS-528/ISS-783) this machine's housekeeping vitals — last_maintenance_at plus its disk
    # and CPU headroom.
    # Same noun as the errors and for the same reason: the subject is the MACHINE. They rode the
    # registry report first, which was the wrong home twice over — that noun is deleted at the
    # server-side-scheduling cutover, and a liveness signal that quietly stops having rows is
    # indistinguishable from a healthy fleet, which is the exact failure it exists to catch.
    #
    # They are DELIBERATELY not part of the change test above. Free disk and load average both move
    # on almost every tick,
    # so gating on it would turn a ten-minute heartbeat into a 30-second one for a signal whose
    # threshold is HALF A DAY (AgentInvariants.MaintenanceStaleAfterHours, 12h since ISS-561 —
    # deliberately not restated as a number the platform can move without us) — the floor is still
    # orders of magnitude finer than anything that reads these. Measured only once a send is
    # decided, so a skipped heartbeat costs no `df`.
    #
    # The edge that leaves, named so the next reader does not rediscover it: this runs in phase_a
    # and reads the marker BEFORE the work phase prunes, so after a gap the server sees the OLD
    # last_maintenance_at for up to one heartbeat window. Harmless, because a machine that was down
    # long enough to exceed the platform's window was already reported by agent_runner_heartbeat_
    # stale at three hours — reporting it is a true statement about a machine that genuinely was
    # off, not a false alarm on a healthy one.
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
          unless e.code == 409
            # Anything that is not a 409 is the platform having a bad moment, not
            # a verdict about this lease. Per-record, because the loop is what
            # renews every OTHER job too: an error that escaped here took every
            # job after this one in iteration order down with it, and kept doing
            # so for as long as the first one's error lasted.
            log("vitals: lease heartbeat failed for ISS-#{record['issue']} (#{e.message}) — continuing")
            next
          end
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
      enforce_verify_timeouts
    end

    # The same, for verify jobs, and it is the BACKSTOP rather than the mechanism:
    # `dev ci verify` has its own watchdog and posts `failure` from it, so this
    # only fires for a worker that never reached its own deadline — one wedged in
    # a syscall, or one whose deadline was overtaken by a machine that slept.
    #
    # It is on the VITALS path deliberately. A hung verify job holds a slot AND
    # holds the lane on `:ci_pending`, and the work phase is exactly what a
    # wedged runner is not running.
    def enforce_verify_timeouts
      Agent::Verify.all.each do |record|
        next unless Agent::Verify.alive?(record["pid"])
        next unless Agent::Verify.timed_out?(record, now: @now)
        decide("verify", "#{Agent::MergeLane.bare(record['repo'])} #{Agent::Verify.short(record['sha'])} exceeded its " \
                         "#{Agent::Verify::JOB_TIMEOUT_SECONDS / 60}m hard timeout — killing pid #{record['pid']}")
        Agent::Verify.kill(record["pid"]) unless @dry_run
      end
    rescue StandardError => e
      log("vitals: verify timeout sweep failed (#{e.class}: #{e.message})")
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
      check_newrelic_ingest
      identity = Agent::Host.cached_identity
      if identity.nil?
        log("no runner identity yet — skipping work phase")
        return
      end
      reap(identity)
      # BEFORE the claim, so an issue this pass wakes can be claimed in the same
      # tick rather than 30 seconds later. It takes no lease and no capacity, so
      # there is nothing for it to take from the claim behind it.
      wake_dependency_deferrals
      claim(identity, self_runner(identity))
    rescue SessionExpired, ApiError => e
      log("work phase: platform error (#{e.message})")
    rescue StandardError => e
      # The backstop (ISS-743). Anything the phase raises that is NOT one of the
      # two platform errors used to travel out of `Tick#run`, past `handle_errors`
      # — which catches only those same two — and kill the process, leaving a
      # backtrace on launchd's stderr as the sole evidence. Phase A has already
      # run by then, so the vitals are fine and nothing looks wrong anywhere a
      # human is looking.
      #
      # A crashing CLAIM is handled closer in, where the lease is in scope
      # (`abandon_crashed_claim`); this catches the rest of the phase — reap,
      # maintenance, the toolchain check — and it records rather than logs so
      # that three in a row files an issue.
      record_work_phase_crash(e)
    end

    def record_work_phase_crash(error)
      decide("work_phase", "work phase CRASHED (#{error.class}: #{error.message}) — vitals are unaffected, " \
                           "and the next tick retries in 30 seconds")
      record_failure(
        WORK_PHASE_ERROR_SOURCE, "#{error.class}: #{error.message}",
        title: ->(host) { "dev-agent: the work phase is crashing on #{host}" },
        explain: "Phase B raised something that is neither `ApiError` nor `SessionExpired`, which before " \
                 "ISS-743 killed the tick outright. It is now contained, but a source that keeps crashing " \
                 "means this machine is doing NO work — no reap, no claim, no maintenance — while its " \
                 "heartbeat stays green, because Phase A runs first and is unaffected.\n\n" \
                 "Backtrace head:\n\n```\n#{Array(error.backtrace).first(5).join("\n")}\n```",
      )
    rescue StandardError => e
      # An exception raised inside a rescue clause PROPAGATES, so a recorder that
      # can itself fail — Agent::Errors writes a file, and the disk this all
      # exists to defend can be full — would reintroduce the exact crash above it
      # is here to contain. A log line is what is left, and it is still strictly
      # more than the tick had before.
      log("work phase: crashed (#{error.class}: #{error.message}) and the crash could not be recorded (#{e.message})")
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
      summary = result.summary
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

    # ---- newrelic ingest against the free tier (ISS-1077) ----
    #
    # `Agent::NewrelicWatch` carries the reasoning for why this is a tick check
    # rather than a producer, and why running it on every runner is not N times
    # the work. What is here is only the wiring.
    #
    # It files on the FIRST actionable reading, like the toolchain check and
    # unlike `record_failure`: a projection crossing the threshold is not a
    # transient blip that a three-strike debounce would filter, and at a daily
    # cadence three strikes would mean three days of a month there are fewer of
    # every day. The server's fingerprint dedup — month plus verdict — is what
    # keeps that from becoming a daily issue.
    def check_newrelic_ingest
      return unless Agent::NewrelicWatch.due?(now: @now)

      key = Agent::NewrelicWatch.key
      if key.nil?
        # Recorded, not silent, and not an issue of its own — see the module
        # header. The cadence marker is stamped so a machine in this state does
        # not retry a credential lookup it cannot satisfy on every 30-second tick.
        Agent::NewrelicWatch.record(nil, now: @now, skipped: "no #{Newrelic::KEY_ENV}") unless @dry_run
        decide("newrelic_ingest", "skipped — this machine cannot resolve #{Newrelic::KEY_ENV} " \
                                  "(`dev agent doctor`); other runners still measure the same account")
        return
      end

      measurement = Agent::NewrelicWatch.measure(key: key, now: @now)
      summary = "#{measurement.verdict}: #{format('%.1f', measurement.projected_gb)} GB projected for " \
                "#{measurement.period_label}#{measurement.free_tier? ? " of #{format('%.0f', measurement.free_limit_gb)} GB free" : ''}"
      if @dry_run
        decide("newrelic_ingest", "#{summary} — would #{measurement.actionable? ? 'file an issue' : 'record the check'}")
        return
      end

      Agent::NewrelicWatch.record(measurement, now: @now)
      decide("newrelic_ingest", summary)
      return unless measurement.actionable?

      file_newrelic_ingest_issue(measurement)
    rescue Newrelic::Error => e
      # A NerdGraph failure is NOT `record_failure`'d into the 3-in-a-row
      # escalation. That channel is for a machine that has stopped working, and
      # this is a third party being unreachable — an outage at NewRelic would
      # otherwise file "the tick is failing on <host>" simultaneously on every
      # runner in the fleet, about the one thing none of them can fix. The marker
      # is stamped either way, so a persistently broken key shows up as a check
      # whose last recorded pass keeps saying it skipped.
      Agent::NewrelicWatch.record(nil, now: @now, skipped: e.message) unless @dry_run
      decide("newrelic_ingest", "could not measure (#{e.message})")
    end

    # Best-effort in the same sense as the toolchain issue above: the marker is
    # already written, so the next cadence retries.
    def file_newrelic_ingest_issue(measurement)
      Agent::Api.create_issue(
        {
          title: NewrelicIngest.issue_title(measurement),
          category: "improvement",
          fingerprint: measurement.fingerprint,
          body: NewrelicIngest.issue_body(measurement),
          claim_on_create: false,
        },
        use_localhost: @use_localhost,
      )
    rescue SessionExpired, ApiError => e
      log("newrelic_ingest: could not file an issue (#{e.message})")
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
      log("could not read the fleet (#{e.message}) — claiming nothing this tick")
      FLEET_UNREADABLE
    end

    # ---- reap ----

    def reap(identity)
      Agent::Jobs.all.each do |record|
        next if Agent::Jobs.alive?(record["pid"])
        begin
          reap_one(record, identity)
        rescue SessionExpired, ApiError => e
          # Per-record, for the reason `heartbeat_leases` is per-record: this
          # loop is what closes out every OTHER dead job, and `claim` runs after
          # it, so one issue whose outcome write hit a 500 used to take the
          # reap of every job behind it — and this runner's next claim — down
          # with it. The verdict is already written to the job record by the
          # time anything in here can raise (see `reap_decision`), so the next
          # tick retries the WRITE and never re-derives the verdict.
          log("reap: ISS-#{record['issue']} could not be closed out (#{e.message}) — " \
              "the recorded outcome is retried next tick")
        end
      end
    end

    def reap_one(record, identity)
      number = record.fetch("issue")
      record, result, prs = reap_decision(record, identity)
      return if @dry_run

      # RECLAIM FIRST, then release the lease. Everything `cleanup` reclaims is
      # keyed by the slug, and the slug is reused verbatim when this issue is
      # resumed — so releasing the lease first opens a window in which the next
      # claim (this runner's own next tick, or another runner's) starts a session
      # on that slug while this one is still deleting its database and its
      # working tree out from under it. The window was always there for the
      # workspace delete; it is not worth widening it to a database drop.
      #
      # Safe to reclaim this early only because the verdict is already ON DISK:
      # `cleanup` deletes the very workspace classification reads, so before
      # ISS-741 a raising `apply_outcome` left a job record whose evidence was
      # gone, and the retry re-derived `nothing_to_do` from it.
      cleanup(record, result)
      apply_outcome(number, record, result, identity, prs)
      Agent::Jobs.finish(record, { "name" => result.name, "status" => result.status, "reason" => result.reason, "url" => result.url })
    end

    # The verdict, classified ONCE and written down before anything acts on it.
    # Returns the job record as it now stands, the outcome, and every PR the run
    # delivered.
    #
    # A recorded verdict WINS over re-classification, and that is the whole fix
    # for ISS-741. Everything below this line in `reap_one` can raise — one
    # platform 500 on the status write is enough — and the job record survives to
    # be reaped again 30 seconds later. By then `cleanup` has deleted the
    # workspace, so `prs_in_workspace` finds nothing and the fallback search is
    # inside its own documented index lag: the retry saw no PR, no plans and exit
    # 0, and called a delivered fix `nothing_to_do` — dismissing a producer-filed
    # issue with its PR sitting ready on GitHub. Same lesson as ISS-364, arriving
    # through the retry path instead of the kill path: when the act of handling an
    # outcome destroys the evidence for it, the evidence has to be written down
    # first.
    def reap_decision(record, identity)
      number = record.fetch("issue")
      recorded = Agent::Outcome.from_h(record.dig("reap", "result"))
      if recorded
        decide("reap", "ISS-#{number} → #{recorded.name} (issue #{recorded.status}): recorded by an earlier " \
                       "reap of this job and applied unchanged — #{recorded.reason}")
        return [record, recorded, Array(record.dig("reap", "prs"))]
      end

      branch = record.fetch("branch")
      workspace = Agent::Workspace.path(record.fetch("slug"))
      started = Time.parse(record.fetch("started_at"))

      # Three handles on the same work, not one, and each covers a way the others
      # miss it: the branch the executor ASSIGNED (ISS-365 — a session that named
      # its own branch is invisible to it), the `ISS-<n>: ` title prefix (already
      # proven as `dev issues reconcile`'s backstop), and the assigned branch's
      # `<branch>_<suffix>` FAMILY, because a run that produced several
      # independent PRs put all but the first on a sibling branch (ISS-657).
      #
      # The whole list, not just the winner: classification takes the strongest
      # PR, and everything else the session delivered is recorded on the issue
      # below rather than dropped on the floor.
      prs = Agent::Github.prs_in_workspace(workspace, branch, number)
      prs = Agent::Github.search_prs(branch, number) if prs.empty?

      result = Agent::Outcome.classify(
        pr: Agent::Github.primary_pr(prs, branch),
        plans_committed: Agent::Github.plans_committed_since?(started),
        # THIS attempt's operations only (ISS-815). The issue directory outlives
        # an attempt, so `started` is what stops a previous attempt's successful
        # run from closing out an attempt that did nothing.
        operations: Agent::Ops.records(number, since: started),
        exit_code: Agent::Jobs.exit_code(number),
        # Did the API refuse to start this session at all (ISS-1129)? Read from
        # the session log rather than inferred from the exit code, which a
        # refusal and a failure share.
        usage_limit: Agent::UsageLimit.detect(number),
        producer_filed: record["producer_filed"],
        attempt: failed_attempts(number, record, identity),
        timed_out: Agent::Jobs.timed_out?(record, now: @now),
        killed: record["killed"],
      )
      siblings = prs.length > 1 ? " (#{prs.length} PRs found)" : ""
      decide("reap", "ISS-#{number} → #{result.name} (issue #{result.status})#{siblings}: #{result.reason}")
      return [record, result, prs] if @dry_run

      stand_down(number) if result.name == "usage_limit"
      [Agent::Jobs.mark_reaped(record, result: result, prs: prs, now: @now), result, prs]
    end

    # One session refused by the usage limit means the NEXT one is refused too:
    # the limit is account-wide with a known reset instant, and the queue is not
    # what is wrong. Without this the tick claims straight through it, which is
    # how three issues spent their entire retry budget in ninety seconds on
    # 2026-08-08 (ISS-1129).
    #
    # Best-effort, like every other bookkeeping step between the verdict and the
    # lease release: a cooldown this tick could not write costs one more refused
    # session, and a refused session now costs the issue nothing.
    def stand_down(number)
      until_time = Agent::UsageLimit.record(Agent::UsageLimit.detect(number), now: @now)
      log("Claude usage limit — claiming nothing until #{until_time.localtime.strftime('%H:%M')}")
    rescue StandardError => e
      log("could not record the usage-limit cooldown (#{e.class}: #{e.message})")
    end

    # Which consecutive failure this attempt would be — the trailing run of
    # leases that ended badly, plus this one (ISS-734). NOT the length of the
    # history: an issue reopened for a regression, reclaimed and handed back
    # carries leases that failed at nothing, and counting those gave up on the
    # issue's first REAL failure and parked it in `needs_input`, which
    # `dev issues claim` never offers again.
    #
    # A history this runner cannot read is one failure — the same conservative
    # answer as before, and the safe direction: it retries rather than gives up.
    def failed_attempts(number, record, identity)
      history = Agent::Api.issue_lease_history(number, token: identity.token, use_localhost: @use_localhost)
      Agent::Outcome.attempt_number(history, lease_id: record["lease_id"])
    rescue ApiError
      1
    end

    # THE SESSION'S OWN STATUS WINS. Settled here rather than left implicit,
    # because ISS-815 asked the question and the answer is load-bearing for every
    # close-out path: if the issue is no longer `claimed`, the session moved it,
    # and this comments instead of writing.
    #
    # Which is not a contradiction of "classification never trusts Claude's
    # prose". The two rules divide cleanly: a session may declare a status by
    # taking a recorded ACTION — `dev issues status --status fixed --url`,
    # `--status needs_review`, `dev issues handoff` — and every one of those is a
    # platform write with a timeline entry and an author. What it may not do is
    # narrate. So the reap defers to a decision the session put on the record and
    # ignores anything it merely said.
    #
    # ONE HOLE, deliberately left open: an unreadable issue (`Agent::Api.issue`
    # raising) falls through to the write, because there is then no way to tell
    # "the session moved it" from "still claimed". Guessing wrong in the other
    # direction is worse — an issue left in `claimed` by a reap that declined to
    # write is invisible to the sweep and to `dev issues claim`, which is the
    # silent-aging failure this whole system is built against. `fixed` and
    # `deployed` are protected anyway: the platform refuses a move back down the
    # ship ladder (ISS-536).
    def apply_outcome(number, record, result, identity, prs = [])
      comment = "#{result.name} by #{hostname} — #{result.reason}"

      issue = begin
        Agent::Api.issue(number, use_localhost: @use_localhost)
      rescue ApiError
        nil
      end
      if issue && issue["status"] != "claimed"
        Agent::Api.comment(number, "Session ended; issue already at `#{issue['status']}`. #{comment}", use_localhost: @use_localhost)
        landed, already = issue["status"], fix_urls(issue)
      else
        Agent::Api.set_status(number, result.status, comment: comment, url: result.url, use_localhost: @use_localhost)
        landed, already = result.status, fix_urls(issue) + [result.url]
      end
      record_extra_fixes(number, prs, already) if SHIPPED_STATUSES.include?(landed)

      release_lease(record, identity, outcome: result.lease_outcome)
    end

    # The statuses `POST /issues/:number/fixes` accepts: an issue that has not
    # shipped has no fix to append to, and asking anyway is a 422.
    SHIPPED_STATUSES = %w[fixed deployed verified].freeze

    def fix_urls(issue) = Array(issue && issue["fixes"]).filter_map { |fix| fix["url"] }

    # Every OTHER PR this run delivered, recorded as an additional fix (ISS-657).
    #
    # A status write carries exactly one url, so before this the reap could only
    # ever name one PR — and a review run routinely ships five or six, each on a
    # sibling branch, each independently mergeable. The rest were findable only by
    # a human reading GitHub, which is the same as not findable: `dev issues show`
    # and the deploy reconciler both read the fix list and nothing else.
    #
    # Merged or ready only. A draft is unfinished and a closed-unmerged PR shipped
    # nothing; recording either as a fix would claim work that does not exist.
    # `already` keeps the timeline quiet on a re-reap and on the urls the session
    # recorded for itself — the endpoint dedupes the row, but not its note.
    #
    # Best-effort by construction: this is bookkeeping standing between the
    # outcome write and the lease release, and no failure of it may cost the
    # release — an unreleased lease strands the issue until it expires.
    def record_extra_fixes(number, prs, already)
      Array(prs).select { |pr| Agent::Github.merged?(pr) || Agent::Github.ready?(pr) }
                .uniq { |pr| pr["url"] }
                .reject { |pr| pr["url"].nil? || already.include?(pr["url"]) }
                .each do |pr|
        Agent::Api.record_fix(number, pr["url"], comment: "Also shipped in #{pr_label(pr)}.",
                                                 use_localhost: @use_localhost)
        log("recorded additional fix #{pr['url']} on ISS-#{number}")
      rescue StandardError => e
        log("could not record additional fix #{pr['url']} on ISS-#{number} (#{e.message})")
      end
    end

    def pr_label(pr) = [pr["repository"], pr["number"]].compact.join("#").then { |l| l.empty? ? pr["url"] : l }

    # The reap names HOW the attempt ended; the lease is the only place that fact
    # is recorded, and the next reap counts it (ISS-734).
    def release_lease(record, identity, outcome: nil)
      Agent::Api.release_lease(record["lease_id"], token: identity.token, use_localhost: @use_localhost,
                                                   outcome: outcome)
    rescue ApiError => e
      log("could not release lease #{record['lease_id']} (#{e.message}) — it will expire on its own")
    end

    def cleanup(record, result)
      drop_session_databases(record.fetch("slug"))
      return unless Agent::Outcome.success?(result)
      Agent::Workspace.delete(record.fetch("slug"))
    rescue StandardError => e
      # Reclamation runs BEFORE the lease is released (see `reap_one`), so it must
      # never be the thing that stops an outcome being recorded. A workspace this
      # tick could not delete is one the hourly workspace GC takes later; an
      # unreleased lease is an issue nobody can claim.
      log("cleanup for #{record['slug']} failed: #{e.class}: #{e.message}")
    end

    # The dead session's OWN databases, dropped by name, immediately.
    #
    # This was `claude-db gc` with no `--apply`, which reclaimed nothing at all:
    # gc has been dry-run-by-default since e87d89e, so the line sampled, wrote a
    # plan to /dev/null and exited 0 for the whole life of the fleet (ISS-588).
    # Passing `--apply` here would have been the wrong repair. gc reaps on AGE,
    # across every session on the machine, and the database this session just
    # abandoned is minutes old — so the one thing this call site is in a position
    # to reclaim is exactly the thing an age cutoff must never take, while
    # everything an age cutoff SHOULD take has nothing to do with the session
    # that happened to die just now.
    #
    # Split by what each caller can know, then. Here: `end`, which drops the
    # databases of ONE session id and touches nothing else. The runner NAMES the
    # session it spawns (CLAUDE_SESSION_ID in `child_env`), so the runner can
    # name it again to reclaim it — no cutoff, no sampling, and no way to reach
    # another session's data even if this one ran for a week. Fleet-wide
    # reclamation — databases from sessions that never reached this line, and the
    # containers and ports left holding none — is age-based and belongs on a
    # cadence, so it runs hourly in Agent::Maintenance instead.
    #
    # Failure is logged rather than raised: a machine with no Docker running
    # still has an outcome to record and a lease to release, and the hourly gc is
    # the backstop for whatever this could not drop.
    def drop_session_databases(slug)
      result = Agent::Shell.capture(Agent::Paths.claude_db_bin, "end",
                                    timeout: CLAUDE_DB_END_TIMEOUT_SECONDS,
                                    env: { "CLAUDE_SESSION_ID" => slug })
      return if result.ok?
      log("claude-db end for #{slug} #{result.summary}: #{Agent::Maintenance.tail(result.output)}")
    rescue StandardError => e
      log("claude-db end for #{slug} failed: #{e.class}: #{e.message}")
    end

    # ---- claim ----

    def claim(identity, runner)
      # `paused` is the ONLY control an operator has to stop one machine from
      # taking new work — the thing you reach for at 3am on the runner producing
      # bad PRs. So the one state it must never be confused with is "we could not
      # find out". This used to rescue the fleet read to nil and fall straight
      # through `runner && runner["paused"]`, which is falsy for nil: a runner
      # paused thirty seconds ago claimed and spawned anyway the moment
      # GET /agent/runners had a blip, because the lease POST is a different
      # endpoint and stays up independently of it.
      #
      # Unknown fails CLOSED, and costs nothing when it is wrong: the next tick is
      # 30 seconds away and the queue keeps.
      if runner == FLEET_UNREADABLE
        log("fleet state unknown — claiming nothing")
        return
      end
      # Cache what the registry says this machine may run at once, for
      # `Agent::Heap` to size the sbt heap from (ISS-753). Here rather than at
      # registration because THIS is the read that happens every work phase, so
      # an operator's `max_concurrency` override reaches the heap within one tick
      # instead of at the next re-registration — and a machine that has never got
      # this far has no sessions to size a heap for.
      Agent::Heap.remember(runner)
      if runner && runner["paused"]
        log("runner is paused — claiming nothing")
        return
      end
      # BEFORE the sessions, and that ordering is what the ISS-763 reservation
      # bought, expressed as priority rather than as arithmetic. A session's work
      # is deferrable — the queue keeps. A pull request is already waiting on a
      # check, and the lane cannot distinguish a check queued behind a four-hour
      # session from a check on a dead runner: it reads `:ci_pending` and waits
      # forever on both.
      #
      # ONE POOL, ONE NUMBER (ISS-848). Both kinds of work claim against the same
      # `max_concurrency`, which is the whole simplification: there is no second
      # scheduler on this box any more, so there is nothing to reserve, nothing to
      # subtract and no way for the two to oversubscribe the machine.
      verify(runner)

      # AFTER `verify`, and that ordering is the point (ISS-1129). A usage limit
      # is the Claude API refusing to start SESSIONS; a verify job is sbt and npm
      # on this machine's own hardware with no model in it, and standing those
      # down too would idle the merge lane over somebody else's quota.
      if (resets_at = Agent::UsageLimit.active(now: @now))
        log("Claude usage limit until #{resets_at.localtime.strftime('%H:%M')} — claiming no issues")
        return
      end

      max = capacity(runner)
      live = live_jobs
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
        # A lease is GRANTED at this point, so nothing below may be allowed to
        # leave the method by raising: an exception here used to travel out of
        # phase_b and out of the tick, leaving the issue `claimed` with no
        # session behind it until the lease expired (ISS-743). Stop claiming
        # after one — whatever broke is very unlikely to be issue-specific, and
        # a loop that keeps claiming would burn the queue one lease at a time.
        begin
          start_job(lease, identity)
        rescue StandardError => e
          abandon_crashed_claim(lease, identity, e)
          break
        end
        live += 1
      end
    end

    # How much work this machine may run at once, of BOTH kinds.
    #
    # The registry derives `max_concurrency` from reported hardware, and that is
    # the whole box — cores and RAM. Until ISS-848 this number had a reservation
    # subtracted from it, because GitHub Actions was a second scheduler pushing CI
    # jobs at the same hardware with no knowledge of this one, and two schedulers
    # each sizing themselves to the same machine is how it ends up swapping at
    # 100% CPU making progress on neither.
    #
    # There is one scheduler now. Verify jobs are claimed by this tick, counted by
    # `live_jobs`, and bounded by this same number — so the subtraction is not
    # merely unnecessary, it would be double-counting.
    def capacity(runner)
      value = (runner && runner["max_concurrency"]) || 1
      [value.to_i, 0].max
    end

    # Everything this box is running: agent sessions AND verify jobs. One number,
    # because they compete for one machine.
    def live_jobs
      Agent::Jobs.all.count { |r| Agent::Jobs.alive?(r["pid"]) } + Agent::Verify.live.length
    end

    # ---- dependency deferrals (ISS-922) ----
    #
    # The other half of `defer_for_dependency`: an issue parked on an unmerged
    # PR used to wait out a full day whatever GitHub did in the meantime, and
    # most PRs in this fleet still merge by hand in GitHub's UI where nothing
    # local sees them. This re-asks, every few minutes, for the issues that are
    # already parked — see Agent::DependencyWake for why that is not the
    # every-tick recheck DEPENDENCY_DEFER_DAYS rejects.
    #
    # Its own rescue rather than the phase's, and it records NOTHING: a sweep
    # that cannot run costs latency on work that was going to come back on its
    # own at the daily expiry, which is the same outcome this fleet had before
    # any of it existed. Letting it reach `record_work_phase_crash` would let a
    # convenience take down the reap and the claim behind it.
    def wake_dependency_deferrals
      return unless Agent::DependencyWake.due?(now: @now)

      result = Agent::DependencyWake.sweep(use_localhost: @use_localhost, dry_run: @dry_run)
      # Marked even on a pass that woke nothing — the cadence is about how often
      # the question is ASKED, and a pass that found nothing must not re-ask 30
      # seconds later.
      Agent::DependencyWake.mark_swept(now: @now) unless @dry_run
      # NAMED rather than silently dropped, for the reason the verify cap is: a
      # bound nobody can see reads as "everything was covered".
      decide("dependency", "#{result.dropped} more deferred issue(s) left for the next pass " \
                           "(cap #{Agent::DependencyWake::CANDIDATE_CAP})") if result.dropped.positive?
      decide("dependency", "the snoozed-issue page filled — there may be deferred issues this pass did not see") if result.truncated
      # A pass that changed nothing is a LOG line and not a decision: it happens
      # every five minutes forever, and "still blocked" is the steady state this
      # sweep exists to sit in. It is written anyway, because a sweep that
      # silently examines nothing is indistinguishable from a healthy quiet
      # fleet, and the symptom of that is a day of latency nobody attributes.
      log("dependency wake: #{result.examined} deferral(s) examined, #{result.woken.length} woken, " \
          "#{result.skipped.length} snoozed for other reasons")
      decide("dependency", "#{result.failed.map { |n| "ISS-#{n}" }.join(', ')} — dependency merged, but the " \
                           "platform refused the wake; the #{DEPENDENCY_DEFER_DAYS}-day deferral still applies") if result.failed.any?
      return if result.woken.empty?

      decide("dependency", "#{result.woken.map { |n| "ISS-#{n}" }.join(', ')} — " \
                           "#{@dry_run ? 'would be woken' : 'dependency merged, woken'} ahead of the " \
                           "#{DEPENDENCY_DEFER_DAYS}-day deferral")
    rescue StandardError => e
      log("dependency wake: sweep failed (#{e.class}: #{e.message}) — the deferrals expire on their own")
    end

    # ---- verify jobs (ISS-848) ----
    #
    # The second unit of work the tick schedules, and deliberately NOT a Claude
    # session: a checkout, a script, an exit code and a commit status. Putting a
    # model in this loop would make the one path that has to be deterministic
    # nondeterministic, and would bill tokens per re-verification — of which there
    # are many, because every merge invalidates every sibling PR's check.
    #
    # Three steps, in this order for a reason each:
    #   reap     first, so a job that finished frees its slot in the same pass
    #            rather than a tick later — and so the lane is handed the result
    #            of a worker that died rather than being left on `:ci_pending`.
    #   scan     throttled well below the tick's own 30 seconds; the walk is an
    #            API call per repo and the thing being waited on takes minutes.
    #   claim    posts `pending` and reads it back, so two boxes scanning the same
    #            repo cannot both build the same sha (fleet-wide dedup, on GitHub
    #            rather than in a file on this runner).
    def verify(runner)
      reap_verify_jobs
      free = capacity(runner) - live_jobs
      return if free <= 0
      return unless Agent::Verify.scan_due?(now: @now)

      scan = Agent::Verify.scan(limit: [free, Agent::Verify::ENQUEUE_CAP].min, now: @now)
      if @dry_run
        decide("verify", "would enqueue #{scan.candidates.map(&:label).join(', ')}") if scan.candidates.any?
        return
      end
      Agent::Verify.mark_scanned(now: @now)
      Agent::Verify.mark_main_scanned(now: @now) if scan.included_main
      # NAMED rather than silently truncated. A cap nobody can see reads as "the
      # fleet is keeping up" when the truth is that N pull requests are waiting on
      # a check; the next pass takes the next batch.
      decide("verify", "#{scan.dropped} more candidate(s) deferred to the next pass (cap #{Agent::Verify::ENQUEUE_CAP})") if scan.dropped.positive?
      scan.candidates.each { |candidate| start_verify_job(candidate) }
    end

    def start_verify_job(candidate)
      token = Agent::Verify.claim(candidate)
      if token.nil?
        # Another box got there first, or the POST failed. Either way this runner
        # does nothing: the sha is somebody else's to answer, or it still has no
        # `ci` entry and the next pass sees it again.
        decide("verify", "#{candidate.label} #{Agent::Verify.short(candidate.sha)} — not claimed here (another runner, or GitHub refused the status)")
        return
      end
      pid = Agent::Verify.spawn(candidate, now: @now)
      decide("verify", "#{candidate.label} building #{Agent::Verify.short(candidate.sha)} " \
                       "(#{candidate.clean? ? 'cold' : 'warm'}, pid #{pid})")
    rescue StandardError => e
      # A verify job that could not be started must not cost the session claims
      # behind it, and must not leave a `pending` status with nothing running: the
      # abandoned-pending rule re-enqueues it, and this says so out loud.
      decide("verify", "#{candidate.label} could not start (#{e.class}: #{e.message}) — the pending status expires into a re-enqueue")
    end

    def reap_verify_jobs
      Agent::Verify.reap(now: @now) do |record, outcome, message|
        decide("verify", "#{Agent::MergeLane.bare(record['repo'])}#{record['pr'] ? "##{record['pr']}" : ''} " \
                         "#{Agent::Verify.short(record['sha'])} #{outcome}: #{message}")
      end
    rescue StandardError => e
      log("verify: reap failed (#{e.class}: #{e.message}) — records are retried on the next tick")
    end

    # THE thing that must not happen: a claim that dies with the lease already
    # taken (ISS-743). The reachable case is `lease["branch"]` — a value the
    # PLATFORM supplies — reaching Agent::Workspace, which raises a plain
    # RuntimeError on anything it could not itself have minted; `start_job`
    # screens that one now, and this is the backstop for every failure nobody
    # has thought of, including the two API errors it is worth releasing for.
    #
    # RELEASE ONLY IF NOTHING IS RUNNING. `start_job` spawns the session BEFORE
    # it writes the claim comment, so a failure in that last call has a live
    # child holding the lease legitimately — releasing it there would expire a
    # session that is working, which is the "machine competes with itself"
    # failure this file's header exists to prevent. The job record is the
    # authority on that, because it is written in the same breath as the spawn.
    #
    # Durably recorded rather than logged, so three of these in a row file an
    # issue instead of scrolling past on launchd's stderr — which was the whole
    # evidence trail the crash used to leave.
    def abandon_crashed_claim(lease, identity, error)
      number = lease["issue_number"]
      running = Agent::Jobs.all.any? { |r| r["lease_id"] == lease["id"] }
      decide("claim", "ISS-#{number} claim FAILED (#{error.class}: #{error.message}) — " \
                      "#{running ? 'a session is already running under this lease, so it stays held' : 'releasing the lease'}")
      record_failure(
        CLAIM_ERROR_SOURCE, "ISS-#{number}: #{error.class}: #{error.message}",
        title: ->(host) { "dev-agent: claims are crashing on #{host}" },
        explain: "`Tick#start_job` raised after the lease was granted. The lease was released (unless a " \
                 "session had already started under it), so the issue returns to the queue rather than " \
                 "sitting `claimed` with nothing running until the lease expires.\n\n" \
                 "Backtrace head:\n\n```\n#{Array(error.backtrace).first(5).join("\n")}\n```",
      )
      return if running || @dry_run

      begin
        Agent::Api.release_lease(lease.fetch("id"), token: identity.token, use_localhost: @use_localhost)
      rescue SessionExpired, ApiError => e
        # Nothing left to try, and it is not worth losing the record above: an
        # unreleased lease expires on its own and the issue returns to `open`.
        log("claim: could not release lease #{lease['id']} (#{e.message}) — it expires on its own")
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

      # The dependency gate (ISS-649). The server already passes over an issue
      # whose blocker is live work; what it cannot see is a blocker sitting at
      # `fixed` on a PR that is still OPEN, which in this fleet is what `fixed`
      # means most of the day. Starting a session on one hands it a dependency
      # that is not on main and forces it to invent a merge order.
      unshipped = Agent::Dependency.unshipped(issue, use_localhost: @use_localhost)
      return defer_for_dependency(lease, identity, number, unshipped, comments) unless unshipped.empty?

      # THE claim-time resolution (ISS-505). nil for every issue that carries its
      # brief inline — human-written ones, and everything filed before pointers
      # existed — so those are untouched. A pointer that IS present and does not
      # resolve stops the claim dead rather than starting a session that would do
      # generic triage under the issue's title.
      begin
        playbook = Agent::Playbook.resolve_in(issue["body"], token: identity.token, use_localhost: @use_localhost)
      rescue Agent::Playbook::MissingError => e
        return abandon_unresolvable_playbook(lease, identity, number, e.message)
      end

      # THE branch, derived from the issue rather than drawn at random (ISS-767):
      # `i<epic>_c<nn>` for a child of an epic, `i<issue>` for a standalone one.
      # Two attempts on one issue therefore compute the SAME name, which makes
      # resume the default instead of something that has to be recorded.
      minted = Agent::Workspace.slug(number, **epic_position(issue))

      # A branch a PRIOR attempt recorded still wins when it differs from what
      # this attempt mints AND its PR is still open — an attempt made before
      # ISS-767 is on `i<issue>_<rand>`, and that PR is the thing to update
      # rather than to duplicate (§4.4.1). A recorded branch with no open PR is
      # finished work and is ignored, exactly as before.
      recorded = usable_resume_branch(lease["branch"])
      resume_repo = recorded && recorded != minted ? Agent::Workspace.resume(recorded) : nil
      slug = resume_repo ? recorded : minted
      # The derived branch resumes ITSELF: same issue, same name, so an open PR
      # on it is this issue's own, and the session updates it in place.
      resume_repo ||= Agent::Workspace.resume(slug)
      workspace = Agent::Workspace.create(slug)
      # The repos the issue names, cloned with the branch already created, so the
      # session opens into a checkout (ISS-562). Best-effort: whatever did not
      # prepare is simply absent from the prompt and the session clones it itself.
      prepared = Agent::Workspace.prepare(slug, issue["repositories"], branch: slug, already_prepared: resume_repo)
      if prepared.continued.any?
        decide("claim", "ISS-#{number} branch #{slug} already exists in #{prepared.continued.join(', ')} — " \
                        "this attempt CONTINUES it rather than starting from origin/main")
      end

      prompt = Agent::Prompt.build(issue: issue, comments: comments, slug: slug,
                                   workspace: workspace, resume_repo: resume_repo,
                                   prepared_repos: prepared.repos, continued_repos: prepared.continued,
                                   playbook: playbook)
      pid = Agent::Jobs.spawn_session(argv: @claude_argv, prompt: prompt, workspace: workspace,
                                      number: number, env: child_env(slug, number))
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

    # The epic this issue belongs to and its position in that epic, as keyword
    # arguments for `Agent::Workspace.slug` — or `{}`, which mints the standalone
    # `i<issue>` form (ISS-767).
    #
    # The epic is free: the claim already reads the issue, and the issue carries
    # its `parent` reference. The POSITION costs one list call, and only for a
    # child — it has to be computed over the epic's whole child set, because
    # `c<nn>` is a rank within that set and nothing on the child itself knows it.
    #
    # `{}` on EVERY failure, and that is the important half. Branch naming must
    # never be able to cost a claim: the standalone form is a perfectly good
    # branch that merely loses the epic prefix for this attempt, while an
    # exception here would land in `abandon_crashed_claim` and burn the dispatch.
    def epic_position(issue)
      parent = issue.dig("parent", "number")
      return {} if parent.to_s.empty?

      numbers = Agent::Api.child_issue_numbers(parent, use_localhost: @use_localhost)
      index = Agent::Workspace.child_index(numbers, issue["number"])
      if index.nil?
        log("claim: ISS-#{issue['number']} is not in epic ISS-#{parent}'s child list — using the standalone branch form")
        return {}
      end
      { parent_number: parent, child_index: index }
    rescue SessionExpired, ApiError => e
      log("claim: could not resolve ISS-#{issue['number']}'s position in epic ISS-#{parent} (#{e.message}) — " \
          "using the standalone branch form")
      {}
    end

    # The recorded branch, screened before it is handed to Agent::Workspace —
    # or nil, meaning "nothing recorded to prefer, use the derived name".
    #
    # `lease["branch"]` is a value the PLATFORM supplies, and Agent::Workspace
    # deliberately REFUSES anything it could not itself have minted, because the
    # unchecked path mkdir_p's — and later rm_rf's — a caller-controlled path
    # under ~/code/ai. That guard is right; what was missing was any answer on
    # this side to it firing (ISS-743). Letting it raise cost the whole tick,
    # with the lease already granted, every ten minutes until the lease expired.
    #
    # Falling back to the derived name costs nothing now: since ISS-767 the slug
    # is computed from the issue, so an unusable recorded branch loses only the
    # chance to update a PR opened under the old random scheme — and the worst
    # case of that is a second PR, which the close-out contract handles
    # (`dev issues fix`), against a runner that dispatches nothing at all.
    def usable_resume_branch(branch)
      return nil if branch.to_s.empty?
      return branch if Agent::Workspace.valid_slug?(branch)

      decide("claim", "recorded branch #{branch.inspect} is not a slug this executor could have minted — " \
                      "ignoring it and starting a fresh attempt")
      nil
    end

    # The first timeline comment, and the audit trail ISS-505 turns on: WHICH
    # playbook this run read and at WHICH VERSION, so the run stays reproducible
    # after the playbook is edited. Written by the runner rather than left to the
    # session, because the runner is the thing that actually did the read.
    #
    # The version is worth recording precisely because the playbook table is
    # copy-on-write (ISS-523): the row this names is still there, and still
    # readable, after ten later edits. A git sha only gave us that while the file
    # was still in git.
    def claim_comment(identity, slug, playbook)
      lines = ["Claimed by #{hostname} (runner #{identity.runner_id}) on branch `#{slug}`."]
      return lines.first if playbook.nil?

      lines << "" << "Playbook: #{playbook.label}"
      lines.join("\n")
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
             "This issue names a playbook (the `Playbook:` line in the body) and this runner could not " \
             "resolve it against `GET /agent/playbooks/:key`, so no session was started. Running it anyway " \
             "would mean generic triage under this issue's title — the ISS-360 failure the pointer exists " \
             "to make impossible.\n\n" \
             "Fix it in /admin/agents/playbooks (or correct the pointer line on this issue), then move it " \
             "back to `open`."
      unless @dry_run
        Agent::Api.set_status(number, "needs_input", comment: text, use_localhost: @use_localhost)
        Agent::Api.release_lease(lease.fetch("id"), token: identity.token, use_localhost: @use_localhost)
      end
      decide("claim", "ISS-#{number}: #{message} — no session started, moved to needs_input")
    end

    # An issue whose dependency has not merged is not work yet, so it is put back
    # DOWN rather than worked or escalated (ISS-649): the lease is released and
    # the issue is deferred a day, at its unchanged status, with the open PR named
    # on its timeline. Tomorrow's tick asks GitHub again, and the day the PR
    # merges the issue dispatches with nothing to clear.
    #
    # Neither of the two obvious alternatives is right. Starting the session is
    # what ISS-644 did: it shipped a stacked PR that could not merge until
    # somebody merged the other one first, and nothing said so except its
    # description. Sending it straight to `needs_input` burns a dispatch on day
    # one to tell Mike something he can already see — a PR of his own, open and
    # healthy, twenty minutes old.
    #
    # RELEASE BEFORE SNOOZE, and that ordering is load-bearing: `snoozed_until` is
    # cleared by any status transition, and releasing the lease reverts the issue
    # from `claimed` to `open`. Snoozing first would leave the issue awake and
    # claimable, and the next tick 30 seconds later would do this all over again.
    # The reverse window — released but not yet deferred — is at most one API call
    # wide, and a tick that claims inside it simply re-runs this gate.
    #
    # A deferral that cannot be recorded escalates instead. Leaving the issue open
    # and undeferred is the one outcome that spins.
    def defer_for_dependency(lease, identity, number, unshipped, comments)
      reasons = Agent::Dependency.describe(unshipped)
      attempt = Agent::Dependency.defer_attempts(comments) + 1
      if attempt >= DEPENDENCY_DEFER_LIMIT
        return escalate_stalled_dependency(lease, identity, number, reasons, attempt)
      end

      text = "#{DEPENDENCY_DEFER_MARKER} — not dispatched, deferred #{DEPENDENCY_DEFER_DAYS} day " \
             "(attempt #{attempt} of #{DEPENDENCY_DEFER_LIMIT}).\n\n" \
             "#{reasons.map { |r| "- #{r}" }.join("\n")}\n\n" \
             "A session started now would be building on code that is not on `origin/main`, and its only " \
             "options are to re-implement the dependency or to stack on it — both of which ISS-649 exists " \
             "to stop. Nothing to do here: this returns to the queue on its own, and the check is rerun " \
             "against GitHub each time."
      unless @dry_run
        Agent::Api.release_lease(lease.fetch("id"), token: identity.token, use_localhost: @use_localhost)
        deferred = Agent::Api.snooze(number, @now + (DEPENDENCY_DEFER_DAYS * 24 * 60 * 60),
                                     comment: text, use_localhost: @use_localhost)
        if deferred.nil? || deferred["snoozed_until"].to_s.empty?
          return escalate_stalled_dependency(lease, identity, number, reasons, attempt,
                                             undeferrable: true)
        end
      end
      decide("claim", "ISS-#{number}: #{reasons.join('; ')} — no session started, deferred #{DEPENDENCY_DEFER_DAYS} day")
    end

    # A dependency that has not merged after a week of daily checks is no longer a
    # scheduling problem, it is a PR nobody merged — and the ONLY thing that can
    # clear it is a human. Deferring it forever would be the silent-aging outcome
    # the whole close-out contract exists to prevent: a snoozed issue is out of the
    # queue AND out of the daily nudge, so nothing would ever say it was stuck.
    #
    # `undeferrable` also says the lease is ALREADY RELEASED: that path reaches
    # here from inside `defer_for_dependency`, after its own release and a snooze
    # that did not take. A second DELETE on a closed lease answers 404/409, which
    # is an ApiError, which unwound the rest of the claim loop — the status write
    # had already landed, so the issue was fine and only the tick's account of
    # what it did was wrong.
    def escalate_stalled_dependency(lease, identity, number, reasons, attempt, undeferrable: false)
      why = undeferrable ? "this runner could not record the deferral" : "#{attempt} daily checks have not cleared it"
      text = "Waiting on a dependency that has not merged, and #{why}.\n\n" \
             "#{reasons.map { |r| "- #{r}" }.join("\n")}\n\n" \
             "Merge the PR (or drop the `blocked_by` edge with `dev issues block #{number} --on <n> --remove` " \
             "if this issue no longer needs it) and move this back to `open`. No session has been started: " \
             "the work is not blocked on a decision, only on the code landing on `origin/main`."
      unless @dry_run
        Agent::Api.set_status(number, "needs_input", comment: text, use_localhost: @use_localhost)
        Agent::Api.release_lease(lease.fetch("id"), token: identity.token, use_localhost: @use_localhost) unless undeferrable
      end
      decide("claim", "ISS-#{number}: #{reasons.join('; ')} — no session started, moved to needs_input")
    end

    # Enforcement, not advice (§4.6): core.hooksPath is injected through
    # GIT_CONFIG_* so it applies to EVERY git the session runs, in every repo,
    # and the pre-push hook refuses a push to ~/code/claude that touches anything
    # outside plans/. The rest of that repo is instructions every future session
    # loads and obeys, which makes it the one place a prompt-injected session
    # could persist itself. Saying so in the prompt is necessary; it is not
    # sufficient.
    #
    # The credentials merged in last are the external-API keys a session needs to
    # VERIFY work whose subject is an external API, rather than designing it
    # against the documentation (ISS-570) — and since ISS-1037 what is merged is
    # their ABSENCE. `Agent::Credentials.withheld` maps every name to nil, which
    # is how `Process.spawn` is told to remove a variable rather than merely not
    # to add one; that matters because the runner's own shell may export a key,
    # and a child inherits what it is not explicitly denied.
    #
    # No line in this file carries a secret any more. A session that needs one
    # runs `dev agent credential exec`, which resolves it into that one command's
    # process and records the use. The reason is blast radius, not access control
    # — every session is the same uid and the env repo is readable on disk, so
    # this can only change how many runs hold a key they were never going to use.
    # Measured on a runner while ISS-1037 was written: 16 of 604 processes
    # carried PLAYBOOK_CLAUDE_KEY, and two of seventeen playbooks use a
    # credential at all. Agent::CredentialUse has the full argument.
    #
    # What the session is TOLD about them (present or absent, and why) is
    # unchanged and is `Agent::Credentials.check`, which carries no values and is
    # rendered into the prompt by Agent::Prompt.
    # CLAUDE_SESSION_ID is set by the RUNNER, not left to the session, and that is
    # what makes the reclamation in `cleanup` possible: `claude-db` names a
    # session's databases after this variable (falling back to the ~/code/ai
    # directory name), so a runner that names the session can drop exactly that
    # session's databases when its process dies, without a cutoff and without
    # touching anyone else's. Left unset it currently resolves to the same string
    # via the workspace fallback — but only for as long as every session's cwd
    # stays inside its workspace, which is not something this code controls.
    # `DEV_AGENT_ISSUE` is what makes `dev agent run-op` a contract rather than a
    # convention (ISS-815): the EXECUTOR names the issue an operation's record is
    # filed under, so a session cannot file one against work it is not doing, and
    # `run-op` refuses outright when the variable is absent — which is what keeps
    # the command from being run by hand on a laptop into some issue's log tree.
    # `SBT_OPTS` is the sbt heap this machine may spend on one slot, derived by
    # `Agent::Heap` rather than written into the instructions as a constant
    # (ISS-753). It is set here as the DEFAULT and is not sufficient on its own:
    # Claude's Bash tool runs a LOGIN shell, so a `~/.zprofile` that exports
    # SBT_OPTS unconditionally overwrites it for every command the session runs.
    # That is why agent/instructions.md tells a session to interpolate
    # `dev agent sbt-opts` in the same shell invocation as sbt, exactly as it
    # does with CONF_DB_DEV_URL. Setting it here still matters: it is what a
    # session's non-login subprocesses see, and it is the value `dev agent
    # sbt-opts` agrees with.
    def child_env(slug, number)
      {
        "DEV_AGENT_ISSUE" => number.to_s,
        "CLAUDE_SESSION_ID" => slug,
        "SBT_OPTS" => Agent::Heap.sbt_opts,
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "core.hooksPath",
        "GIT_CONFIG_VALUE_0" => Agent::Paths.githooks_dir,
        "DEV_AGENT_CLAUDE_REPO" => Agent::Paths.claude_repo,
      }.merge(Agent::Credentials.withheld)
    end

    # ---------------- plumbing ----------------

    # Non-blocking, so ticks never pile up: a tick that cannot take the lock
    # skips that phase and the next one is 30 seconds away. The mechanics live in
    # Agent::Paths.with_lock, next to the paths being locked and to the atomic
    # writes that are the reason a lock is on a separate file at all — Agent::
    # Errors needs the same primitive with a blocking acquire (ISS-742), and two
    # hand-rolled copies of an flock dance is exactly how the two of them would
    # come to disagree.
    def with_lock(path, &block)
      Agent::Paths.with_lock(path, &block)
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
