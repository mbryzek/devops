require 'json'
require 'socket'
require 'time'
require 'agent/errors'
require 'agent/escalation'
require 'agent/paths'
require 'agent/shell'

# The runner-local half of CI (ISS-763), for the merge lane ISS-754 shipped.
#
# The lane reads ONE fact off a PR: did the `ci` check pass on the exact commit
# about to be squashed. Everything here exists so that fact is worth reading —
# so that a green means the code is good and a red means the code is bad, on a
# machine that is also running agent sessions, that also prunes its own disk,
# and whose registry credential expires on its own schedule.
#
# THREE THINGS, and they are three because each is a different way the check
# lies rather than three features of one feature:
#
#   slots       The box has one capacity, and two schedulers want it. The tick
#               claims agent sessions; GitHub pushes CI jobs at whatever runner
#               listeners are installed. Neither can see the other, so without
#               an agreed split they oversubscribe and the machine swaps —
#               making no progress on either while looking busy on both.
#   preflight   A runner that cannot pull the DB image, or has no disk, cannot
#               tell you anything about your code. That must not render as
#               "your tests failed" — it is the runner, and the response to it
#               is to page someone, not to park the PR and go read the diff.
#   clean       Warm incremental state is the whole reason to self-host, and
#               stale incremental state is the one failure with no human
#               downstream: a FALSE GREEN the lane will merge. So the warm path
#               is the PR path only, and `main` and the nightly are cold.
#
# WHY NOTHING HERE IS A DAEMON. Agent::Tick's header is emphatic that the
# dispatcher keeps no local state beyond "is this pid alive", and a slot manager
# with leases and expiry would be exactly the thing it refuses to be. So the
# semaphore below is N lock files held by `flock` for as long as the build
# process lives: liveness is the kernel's problem, a killed job releases its slot
# because the fd closes, and there is no record to leak, expire, or reconcile.
module Agent
  module Ci
    # EX_TEMPFAIL. The exit status every infrastructure fault leaves, and the one
    # number a workflow step has to know: `dev ci preflight` and `dev ci run`
    # both use it, and the reusable workflow branches on it to label the failure
    # as the runner's rather than the branch's.
    #
    # 75 rather than a number of our own because sysexits.h already means this
    # ("temporary failure; the user is invited to retry"), and a CI step that
    # exits 1 is indistinguishable from the suite it wrapped.
    INFRA_EXIT_CODE = 75

    # How long a CI job waits for a slot before giving up.
    #
    # Long, because the thing it is queueing behind is another CI job of the same
    # kind — minutes, not the hours an agent session runs (which is why agent
    # sessions do not share these slots dynamically; see `reserved`). Bounded,
    # because a wait with no end is a check that never answers, and the lane
    # cannot tell "still queueing" from "this runner is wedged".
    #
    # Timing out is an INFRASTRUCTURE fault, not a test failure: a box so
    # oversubscribed that a job waited half an hour is a capacity problem, and
    # saying so is what makes the buy-a-mini trigger in the design measurable
    # rather than a feeling.
    SLOT_WAIT_SECONDS = 30 * 60

    # Poll interval while waiting. `flock` has no portable "wait with a
    # deadline", so the wait is a poll — coarse on purpose, because the thing
    # being waited on takes minutes and a tight loop would spend the CPU the wait
    # exists to protect.
    SLOT_POLL_SECONDS = 5

    # Free space below which the box is not fit to run a build.
    #
    # Deliberately BELOW Agent::Maintenance::PRESSURE_FLOOR_BYTES (50G): that
    # floor is where the machine starts pruning harder, and pruning is a normal
    # state a build should run through rather than refuse. This one is where a
    # build stops being trustworthy — a full disk has already faked spec failures
    # on this fleet once, and a fake red on a PR nobody reads is a fix that gets
    # blamed on the wrong change.
    DISK_FLOOR_BYTES = 20 * 1_000_000_000

    # Agent::Errors source for a preflight fault. Fixed, so the streak that
    # escalates it and the entries that feed the streak can never disagree about
    # what they are counting.
    ERROR_SOURCE = "ci_preflight".freeze

    # Bounds on every probe below. A preflight that hangs is worse than one that
    # fails: it holds a runner slot and the check sits pending, which the lane
    # reads as `:ci_pending` and waits on forever.
    PROBE_TIMEOUT_SECONDS = 60

    # The caches that make a self-hosted runner worth having. Free minutes are
    # why hosted is unaffordable; PRESERVED INCREMENTAL STATE is why self-hosted
    # is fast, and it is the larger effect — a cold platform `Test/compile` is
    # ~8 minutes of which almost none is compilation nobody has done before.
    #
    # These live in $HOME, outside any workspace, so they survive `actions/
    # checkout` regardless of what it does to the tree. `target/` does not — it
    # is inside the checkout, which is why the workflow needs `clean: false` and
    # why `clean_build?` below exists to take it away again when it is not safe.
    WARM_CACHE_DIRS = %w[~/.cache/coursier ~/.ivy2 ~/.sbt ~/.npm].freeze

    module_function

    # ---------------- provisioning ----------------

    # This machine's CI configuration, written by `dev ci install` and read by
    # everything else — including Agent::Tick, which is why it is a file on the
    # box rather than a field on the platform's runner row.
    #
    # The registry derives `max_concurrency` from reported hardware, which is
    # right for a fact about the hardware. How that capacity is SPLIT is not a
    # fact about the hardware: it is an operator's decision about this box, made
    # when the runner is installed on it, and it has to be readable by a tick
    # running while the platform is unreachable.
    #
    # Absent is the normal state. Most machines run no CI, and on them every
    # entry point here is a no-op.
    def config
      Agent::Paths.read_json(Agent::Paths.ci_config_file) || {}
    end

    # Slots reserved on this box for CI, and therefore both the ceiling on
    # concurrent CI jobs here and the amount Agent::Tick subtracts from
    # max_concurrency before it claims.
    #
    # RESERVED, not borrowed, and that asymmetry is the whole design. An agent
    # session runs for hours and its work is deferrable — the queue keeps. A CI
    # job runs for minutes and something is already waiting on it: a PR, and a
    # merge lane that cannot distinguish a check queued behind a four-hour
    # session from a check on a dead runner. So CI gets a fixed floor it never
    # has to wait hours for, and the tick — the elastic side — gives it up.
    #
    # The cost is honest and small: when no PR is open, `slots` cores sit idle
    # rather than running one more session. See docs/ci.md for the arithmetic
    # this was chosen against.
    def reserved
      value = config["slots"]
      return 0 unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
      [value.to_i, 0].max
    end

    def enabled? = reserved.positive?

    # ---------------- the slot semaphore ----------------

    def slot_file(index) = File.join(Agent::Paths.ci_slots_dir, "slot-#{index}.lock")

    # Run `block` holding one of this machine's CI slots, waiting up to
    # `wait_seconds` for one. Returns the block's value, or `:timed_out` if none
    # came free — the caller turns that into INFRA_EXIT_CODE rather than a test
    # failure.
    #
    # The lock is held by THIS process for the duration of the block, which is
    # why the whole build runs inside one `dev ci run` rather than the workflow
    # acquiring in one step and releasing in another. A lease spanning steps
    # would need an owner, an expiry and a reaper; an fd needs none of them, and
    # a job killed mid-build releases its slot the instant the kernel closes it.
    def with_slot(wait_seconds: SLOT_WAIT_SECONDS, poll_seconds: SLOT_POLL_SECONDS, clock: -> { Time.now })
      count = reserved
      raise "CI is not provisioned on this machine (#{Agent::Paths.ci_config_file} has no slots). Run `dev ci install`." if count.zero?

      Agent::Paths.mkdir_p(Agent::Paths.ci_slots_dir)
      deadline = clock.call + wait_seconds
      loop do
        # The success path leaves through the `return` inside the block, with
        # try_slot's `ensure` unlocking behind it. Every other path here means
        # every slot was busy.
        count.times { |index| try_slot(index) { return yield(index) } }
        # The remaining time bounds the sleep, so `--wait 60` waits 60 seconds
        # rather than the next multiple of the poll interval. A wait that
        # silently rounds up to the poll granularity would make the deadline a
        # suggestion, and the whole value of the deadline is that it is the one
        # thing distinguishing a busy machine from a wedged one.
        remaining = deadline - clock.call
        return :timed_out if remaining <= 0
        sleep([poll_seconds, remaining].min)
      end
    end

    # Take slot `index` if it is free, yield, and release. Returns `:busy`
    # without yielding when another process holds it.
    def try_slot(index)
      file = File.open(slot_file(index), File::RDWR | File::CREAT, 0600)
      begin
        return :busy unless file.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          file.truncate(0)
          file.write("#{Process.pid} #{Time.now.utc.iso8601}\n")
          file.flush
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      ensure
        file.close
      end
    end

    # How many CI slots are busy right now — for `dev ci status` and nothing
    # else. It is NOT what the tick subtracts: the tick subtracts the whole
    # reservation, so that a CI job arriving on an idle box does not have to wait
    # for a session to finish (see `reserved`).
    #
    # Probing is a non-blocking take-and-release, so a slot this very process
    # holds reads as free — `dev ci status` run from inside `dev ci run` will
    # undercount by one. That is the only caller it is wrong for and it is not
    # worth an ownership record to fix.
    def slots_held
      (0...reserved).count do |index|
        next false unless File.exist?(slot_file(index))
        try_slot(index) { false } == :busy
      end
    end

    # ---------------- the false-green rule ----------------

    # Should this run throw away the incremental state before building?
    #
    # THE ONE FAILURE WITH NO HUMAN DOWNSTREAM. Everything else here produces a
    # red that someone reads; stale zinc analysis produces a GREEN, and the lane
    # merges greens without asking. So warmth is spent only where a human still
    # sees the result:
    #
    #   pull_request  warm. The fast path, and the point of self-hosting. A false
    #                 green here is bounded by the cold build on `main`, which
    #                 runs before anything is built on top of it.
    #   push (main)   cold. The tree every PR is measured against.
    #   schedule      cold. The nightly, which is what notices that the warm path
    #                 has been lying all day.
    #   anything else cold. An event nobody listed is an event nobody reasoned
    #                 about, and the safe answer to "should I trust this cache"
    #                 has to be no.
    #
    # Stated as one comparison rather than a list of cold events on purpose:
    # warmth is an allowlist of exactly one entry, so a new trigger added to a
    # workflow a year from now is cold until somebody decides otherwise.
    def clean_build?(event:) = event.to_s != "pull_request"

    # ---------------- preflight ----------------

    # One probe's answer. `remedy` is the line a human runs; it is part of the
    # check rather than of the docs because the person reading it is looking at a
    # red PR at some hour, and a fault that does not say what to do about it gets
    # retried instead of fixed.
    Check = Struct.new(:name, :ok, :detail, :remedy, keyword_init: true) do
      def ok? = !!ok
    end

    Report = Struct.new(:checks, keyword_init: true) do
      def faults = checks.reject(&:ok?)
      def ok? = faults.empty?
      def summary = faults.map { |c| "#{c.name}: #{c.detail}" }.join("; ")
    end

    # The probes, in the order a human would want them: the ones that explain the
    # most other failures first, so the first fault reported is the root cause
    # rather than a symptom of it.
    #
    # `needs` names what this repo's build actually touches, so a Ruby suite is
    # not held to a Docker daemon it never starts. Unknown names are ignored
    # rather than rejected — a workflow naming a need this version does not know
    # about should run, not fail closed on its own config.
    def preflight(needs: [], now: Time.now)
      wanted = Array(needs).map(&:to_s)
      checks = [disk_check]
      checks << docker_check if wanted.include?("docker")
      checks << registry_check if wanted.include?("registry")
      checks << database_check if wanted.include?("database")
      Report.new(checks: checks).tap { |report| record_fault(report, now: now) }
    end

    def disk_check
      free = free_bytes(Dir.home)
      if free.nil?
        return Check.new(name: "disk", ok: false, detail: "could not read free space on #{Dir.home}",
                         remedy: "df -g #{Dir.home}")
      end
      Check.new(name: "disk", ok: free >= DISK_FLOOR_BYTES,
                detail: "#{gb(free)}G free, floor is #{gb(DISK_FLOOR_BYTES)}G",
                remedy: "dev agent maintenance --force")
    end

    # The daemon, not the CLI. `docker --version` answers from the binary and
    # says nothing about whether anything can run, which is the failure mode that
    # matters: a wedged daemon on a box whose `docker` is perfectly installed.
    def docker_check
      result = probe("docker", "info", "--format", "{{.ServerVersion}}")
      Check.new(name: "docker", ok: result.ok?,
                detail: result.ok? ? "daemon #{result.output.strip}" : "daemon unreachable (#{result.summary})",
                remedy: "open -a Docker && docker info")
    end

    # THE 30-DAY FAILURE. What expires is doctl's own DigitalOcean auth, not a
    # token we store — the registry credential is minted per process and lives
    # for the length of it (lib/registry_auth.rb, ISS-578), deliberately, so
    # there is nothing on this box to leak. `doctl account get` is therefore the
    # exact predicate: it is what minting will do in a moment, asked in advance.
    #
    # Checking it here rather than letting the pull fail is the whole point. An
    # expired credential surfaces as `claude-db start` failing to pull the DB
    # image, several minutes in, as a wall of red spec failures on a PR that did
    # nothing wrong.
    def registry_check
      result = probe("doctl", "account", "get", "--format", "Status", "--no-header")
      ok = result.ok? && result.output.strip.downcase.include?("active")
      Check.new(name: "registry", ok: ok,
                detail: ok ? "doctl auth is live" : "doctl cannot authenticate to DigitalOcean (#{result.summary})",
                remedy: "doctl auth init")
    end

    # A port from the range `claude-db` allocates out of. Exhaustion is the
    # ordinary way a busy box stops being able to start a session database, and
    # it fails at `claude-db start` — again minutes in, again as test failures.
    def database_check
      result = probe(Agent::Paths.claude_db_bin, "next-port")
      ok = result.ok? && result.output.strip.match?(/\A\d+\z/)
      Check.new(name: "database", ok: ok,
                detail: ok ? "port #{result.output.strip} available" : "no session-database port available (#{result.summary})",
                remedy: "claude-db gc --days 1")
    end

    # Agent::Shell raises Errno::ENOENT for a binary that does not exist, exactly
    # as Open3 does, because "not installed" and "ran and failed" are different
    # facts. Both are the same fact HERE — the runner cannot do the thing — so
    # this flattens them into a failing Result rather than making every probe
    # rescue for itself.
    def probe(*cmd)
      Agent::Shell.capture(*cmd, timeout: PROBE_TIMEOUT_SECONDS)
    rescue Errno::ENOENT
      not_installed(cmd.first)
    end

    NotInstalled = Struct.new(:success?, :exitstatus)

    def not_installed(binary)
      Agent::Shell::Result.new(output: "#{binary} is not installed",
                               status: NotInstalled.new(false, 127),
                               timed_out: false, timeout: PROBE_TIMEOUT_SECONDS)
    end

    def free_bytes(path)
      stat = Agent::Shell.capture("df", "-k", path, timeout: 10)
      return nil unless stat.ok?
      fields = stat.output.lines.last.to_s.split
      return nil if fields.length < 4
      Integer(fields[3]) * 1024
    rescue ArgumentError, TypeError, Errno::ENOENT
      nil
    end

    def gb(bytes) = (bytes / 1_000_000_000.0).round(1)

    # A fault is ESCALATED on the machine as well as reported to the job, and
    # that is the half of failure mode 2 the annotation cannot cover.
    #
    # A red CI job is read by whoever opened the PR. A BROKEN RUNNER is read by
    # nobody: an expired DigitalOcean credential turns every job on the box red,
    # on branches that did nothing wrong, and the only evidence is a wall of red
    # that looks like a code failure. Somebody has to be told about the machine.
    #
    # Through Agent::Escalation, which is the fleet's existing path for exactly
    # this — three consecutive failures of one source files an issue — rather
    # than a second alerting mechanism with its own idea of what "in a row"
    # means. A clean preflight CLEARS the source, which is what makes the streak
    # mean in a row rather than ever.
    def record_fault(report, now: Time.now)
      return Agent::Errors.clear(ERROR_SOURCE) if report.ok?

      Agent::Escalation.record(
        ERROR_SOURCE, report.summary, host: hostname, now: now,
        title: ->(host) { "CI runner #{host} cannot produce a verdict" },
        explain: "`dev ci preflight` has failed on this runner three times in a row, so every CI job " \
                 "it accepts is red for a reason that has nothing to do with the branch — and the " \
                 "merge lane is parking those PRs.\n\n" \
                 "Each fault above names the command that fixes it. Until one of them does, take the " \
                 "machine out of the pool rather than leaving it to fail every job it is handed:\n\n" \
                 "```\ndev ci install --slots 0\n```\n",
      )
    rescue StandardError
      # Recording is decoration on a report that has already been computed. A
      # state dir it cannot write, or a platform it cannot reach, must not turn a
      # preflight into a crashed step — the job would then fail for a reason
      # unrelated to anything it checked, which is the exact confusion this whole
      # file exists to prevent.
      nil
    end

    # Socket rather than a `hostname` subprocess: the escalation runs on the
    # fault path, which is the one path where the machine is already known to be
    # unhealthy, and spawning a process to learn its own name there is a way to
    # fail while reporting a failure.
    def hostname
      Socket.gethostname
    rescue StandardError
      "unknown"
    end
  end
end
