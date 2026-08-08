require 'json'
require 'socket'
require 'time'
require 'agent/errors'
require 'agent/escalation'
require 'agent/heap'
require 'agent/paths'
require 'agent/shell'

# The machine-side half of CI: is this runner fit to produce a verdict, and may
# it trust what it has cached.
#
# The lane reads ONE fact off a PR: did the `ci` check pass on the exact commit
# about to be squashed. Everything here exists so that fact is worth reading —
# so that a green means the code is good and a red means the code is bad, on a
# machine that is also running agent sessions, that also prunes its own disk,
# and whose registry credential expires on its own schedule.
#
# WHAT USED TO BE HERE AND IS GONE (ISS-848). ISS-763 also carried a slot
# semaphore, a `~/.platform/ci.json` reservation and a subtraction inside
# `Agent::Tick#session_capacity`. All three existed because GitHub Actions was a
# SECOND SCHEDULER on hardware the tick already schedules, and neither could see
# the other. The `ci` check is produced by a fleet job now (Agent::Verify), which
# claims through the same tick against the same `max_concurrency` — so there is
# one scheduler, one number, and nothing left to arbitrate. Do not reintroduce a
# reservation without reintroducing the second scheduler that made it necessary.
#
# TWO THINGS, and they are two because each is a different way the check lies
# rather than two features of one feature:
#
#   preflight   A runner that cannot pull the DB image, or has no disk, cannot
#               tell you anything about your code. That must not render as
#               "your tests failed" — it is the runner, and the response to it
#               is to page someone, not to park the PR and go read the diff.
#   clean       Warm incremental state is the whole reason to build on our own
#               hardware, and stale incremental state is the one failure with no
#               human downstream: a FALSE GREEN the lane will merge. So the warm
#               path is the PR path only, and `main` and anything unlisted are
#               cold.
module Agent
  module Ci
    # EX_TEMPFAIL. The exit status every infrastructure fault leaves, and the one
    # number a build script has to know: `dev ci preflight` uses it, and
    # `dev ci verify` branches on it to label the failure as the runner's rather
    # than the branch's — which is what makes the status description say "fix the
    # machine" instead of "read the diff".
    #
    # 75 rather than a number of our own because sysexits.h already means this
    # ("temporary failure; the user is invited to retry"), and a CI step that
    # exits 1 is indistinguishable from the suite it wrapped.
    INFRA_EXIT_CODE = 75

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

    # The caches that make building on our own hardware worth it. Hosted minutes
    # are why hosted CI is unaffordable; PRESERVED INCREMENTAL STATE is why this
    # is fast, and it is the larger effect — a cold platform `Test/compile` is
    # ~8 minutes of which almost none is compilation nobody has done before.
    #
    # These live in $HOME, outside any checkout, so nothing a build does to a
    # tree can take them away. `target/` and `node_modules/` do NOT — they are
    # inside the checkout, which is why `Agent::Verify.checkout` cleans with `-fd`
    # (keeping ignored files) on the warm path and `-xfd` on the cold one, and why
    # `clean_build?` below decides which.
    WARM_CACHE_DIRS = %w[~/.cache/coursier ~/.ivy2 ~/.sbt ~/.npm].freeze

    module_function

    # ---------------- the false-green rule ----------------

    # Should this run throw away the incremental state before building?
    #
    # THE ONE FAILURE WITH NO HUMAN DOWNSTREAM. Everything else here produces a
    # red that someone reads; stale zinc analysis produces a GREEN, and the lane
    # merges greens without asking. So warmth is spent only where a human still
    # sees the result:
    #
    #   pull_request  warm. The fast path, and the whole point of building on our
    #                 own hardware. A false green here is bounded by the cold
    #                 build on `main`, which runs before anything is built on top
    #                 of it.
    #   push (main)   cold. The tree every PR is measured against, rebuilt on
    #                 every new tip and at least daily — which is what notices
    #                 that the warm path has been lying (Agent::Verify).
    #   anything else cold. An event nobody listed is an event nobody reasoned
    #                 about, and the safe answer to "should I trust this cache"
    #                 has to be no.
    #
    # Stated as one comparison rather than a list of cold events on purpose:
    # warmth is an allowlist of exactly one entry, so a trigger somebody adds a
    # year from now is cold until it is deliberately made warm.
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
    #
    # `heap:<N>G` is the one entry that is a QUANTITY rather than a name, and the
    # one exempt from the ignore-what-you-do-not-know rule: see `heap_check`.
    def preflight(needs: [], now: Time.now)
      wanted = Array(needs).map(&:to_s)
      checks = [disk_check]
      checks << docker_check if wanted.include?("docker")
      checks << registry_check if wanted.include?("registry")
      checks << database_check if wanted.include?("database")
      heap = heap_check(Agent::Heap.requirement(wanted))
      checks << heap if heap
      Report.new(checks: checks).tap { |report| record_fault(report, now: now) }
    end

    # THE BACKSTOP FOR THE SCHEDULER, not a second implementation of it
    # (ISS-1123). Agent::Verify already refuses to CLAIM a job this box cannot
    # give the heap for, so in the ordinary case this never fires. It exists for
    # the cases where the claim-time match could not be made or was not made at
    # all: a hand-run `dev ci verify` on the small box — which is exactly how a
    # repo's first build is confirmed, and how ISS-1099 is told to confirm
    # platform's — and a tick whose registry read failed, where `max_concurrency`
    # is unknown and the derived heap falls to the floor.
    #
    # What it buys in those cases is the WHOLE point of the issue: the failure
    # renders as an infrastructure fault (exit 75, "fix the machine") instead of
    # as an OOM the lane reads as a red suite. A false red on a platform PR costs
    # a human an investigation into a scheduling mistake, and at 27 open PRs it
    # reads as "platform's suite is flaky" rather than as a scheduler bug.
    #
    # nil when the build declares no heap, which is every Node and Elm suite and
    # was every repo before this: no declaration, no check, no behaviour change.
    def heap_check(requirement)
      return nil if requirement.nil?
      if requirement == :malformed
        return Check.new(name: "heap", ok: false,
                         detail: "the `# ci-needs:` heap token does not parse — it must read `heap:<N>G`, e.g. `heap:12G`",
                         remedy: "fix the `# ci-needs:` line in ci/build.sh")
      end
      have = Agent::Heap.gigabytes_here
      Check.new(name: "heap", ok: have >= requirement,
                detail: "this machine gives #{have}G, the build declares heap:#{requirement}G",
                remedy: "run it on a runner with more RAM per slot — `dev agent sbt-opts --explain` shows the arithmetic")
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
        explain: "`dev ci preflight` has failed on this runner three times in a row, so every verify " \
                 "job it takes is red for a reason that has nothing to do with the branch — and the " \
                 "merge lane is parking those PRs.\n\n" \
                 "Each fault above names the command that fixes it. Until one of them does, take the " \
                 "machine out of the pool rather than leaving it to fail every job it claims. Pausing " \
                 "covers both kinds of work, because a verify job claims through the same tick an " \
                 "agent session does (ISS-848):\n\n" \
                 "```\ndev agent pause\n```\n",
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
