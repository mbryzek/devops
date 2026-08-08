require 'agent/host'
require 'agent/paths'
require 'agent/shell'

module Agent
  # THE SBT HEAP, DERIVED PER MACHINE (ISS-753).
  #
  # There used to be one number, `-Xmx12G`, written into agent/instructions.md and
  # into templates/ci/build-scala.sh, and it was wrong on both fleet machines in
  # opposite directions: 3 x 12G of heap ceiling requested on a 24G box at
  # `max_concurrency` 3, and one session capped at 12G on a 64G box at
  # concurrency 1. A constant cannot be right on both, and the two facts that
  # make it derivable -- physical memory and how many sessions this machine may
  # hold at once -- are already known here.
  #
  #   heap = clamp(RAM / max_concurrency * 0.6, MIN_GB, MAX_GB)
  #
  # RAM / max_concurrency is the PER-SLOT BUDGET, and it is the same accounting
  # the platform sizes `max_concurrency` with (`InternalAgentRunnersDao.derive
  # MaxConcurrency`: roughly 8G per concurrent session). 0.6 of it goes to the
  # sbt JVM because the slot has to hold more than the sbt JVM: platform forks
  # its test JVMs (`Test / fork := true`, `-Xmx4g` each, up to `cores / 5` at
  # once), and the session's Postgres container, `claude`, and the OS page cache
  # that coursier and zinc live off all come out of the same slot.
  #
  # MEASURED, not chosen (2026-08-07, on the 24G/10-core runner, WHILE two other
  # sessions were live -- one of them an sbt with the 40G heap described below):
  # platform's cold `Test/compile` at `-Xmx4G` completed in 2m46s with a peak RSS
  # of 5.30 GB. The recorded baseline is ~8 min at 12G. So 4G is the floor
  # because it is demonstrated, not because it is cautious, and MAX_GB is a
  # ceiling on a RUNAWAY rather than on a need -- `Agent::Jobs` already documents
  # what a stray sbt JVM does to a machine, and heap past the working set buys
  # later GCs, not throughput.
  #
  # WHY `SBT_OPTS` AND NOT `-J-Xmx` ON THE COMMAND LINE. sbt's launcher builds
  # its java command as `java $JAVA_OPTS $SBT_OPTS ... -jar sbt-launch.jar`, and
  # a `-J-Xmx` argument is folded into the JAVA_OPTS half. Duplicate `-Xmx` flags
  # resolve last-one-wins, so SBT_OPTS beats `-J-Xmx`, beats `.jvmopts`, and
  # beats the launcher's own 1G default. That is not a theory: on 2026-08-07 a
  # live session on the 24G runner was observed running
  #
  #   java -Dfile.encoding=UTF-8 -Xmx12G ... -Xms40G -Xmx40G -Xss2M -jar sbt-launch.jar
  #
  # -- the `-Xmx12G` it was told to pass, silently overridden by the `SBT_OPTS`
  # in `~/.zprofile`. The instruction had been ineffective on that box for as
  # long as it had been given.
  #
  # `-Xss4M` is included because supplying `-Xmx` SUPPRESSES the launcher's own
  # memory defaults, and `-Xss4M` is one of them. Dropping it would quietly hand
  # Scala 3's compiler the JVM's much smaller default stack.
  #
  # THE LOGIN SHELL IS WHY THIS IS NOT SIMPLY AN ENTRY IN `child_env`. Claude's
  # Bash tool runs `/bin/zsh -l`, so `~/.zprofile` is re-sourced for every
  # command a session runs, and an unconditional `export SBT_OPTS=...` there
  # overwrites whatever the executor put in the environment. Verified on the
  # runner: `SBT_OPTS=MARKER zsh -lc 'echo $SBT_OPTS'` prints the profile's
  # value, not MARKER. So the environment is set for everything that does NOT go
  # through a login shell (the CI verify build, any direct spawn), `sbt_opts`
  # below is what a session interpolates in the same shell invocation as sbt --
  # exactly as `CONF_DB_DEV_URL` is -- and `profile_override` is how the machine
  # says out loud that its own profile is fighting both.
  module Heap
    GB = 1024**3

    # Of the per-slot budget. The rest is the forked test JVMs, Postgres, and the
    # page cache; see the header.
    SLOT_FRACTION = 0.6

    # Demonstrated to compile platform cold. Never lower this without repeating
    # that measurement.
    MIN_GB = 4

    # A bound on a runaway, not on a need.
    MAX_GB = 24

    # Restores the launcher default that supplying -Xmx suppresses.
    STACK = "-Xss4M".freeze

    PROBE_TIMEOUT_SECONDS = 10

    # What makes an inherited SBT_OPTS a hazard rather than a preference: a
    # PINNED heap. `-Xms` is worse than `-Xmx` -- it commits the heap at JVM
    # start, so a shell configured with `-Xms40G` reserves 40G whether the build
    # needs it or not, and on a 24G machine that is memory the OS cannot give to
    # the page cache sbt depends on.
    PINS_HEAP = /-Xm[sx]\s*\d/.freeze

    module_function

    # ---- the derivation (pure, and the only place the arithmetic lives) ----

    def gigabytes(memory_bytes:, concurrency:)
      slots = [concurrency.to_i, 1].max
      gb = memory_bytes.to_f / GB
      return MIN_GB unless gb.positive?
      ((gb / slots) * SLOT_FRACTION).floor.clamp(MIN_GB, MAX_GB)
    end

    def opts(memory_bytes:, concurrency:)
      "-Xmx#{gigabytes(memory_bytes: memory_bytes, concurrency: concurrency)}G #{STACK}"
    end

    # ---- this machine ----

    def memory_bytes = Agent::Host.sysctl("hw.memsize")&.to_i

    # The `max_concurrency` the platform last told this machine about, or nil.
    #
    # Read from a file rather than from the API because this is consulted on the
    # path to every sbt invocation, and a heap that depended on the network would
    # be wrong exactly when the network is. nil is not filled in with a local
    # re-derivation of the server's rule: the number is the SERVER's, including
    # an operator's override (the 64G laptop is pinned to 1), and a second copy
    # of the formula here would disagree with it the day either changes. An
    # unknown concurrency falls back to MIN_GB below -- the conservative end,
    # self-healing on the next tick 30 seconds later.
    def concurrency
      value = Agent::Paths.read_json(Agent::Paths.runner_file)&.fetch("max_concurrency", nil)
      value&.to_i&.positive? ? value.to_i : nil
    end

    # Called wherever the tick learns this machine's own registry row. Tolerates
    # nil and a row without the key: a heap is not worth an exception on the
    # claim path.
    def remember(runner, now: Time.now)
      value = runner.is_a?(Hash) ? runner["max_concurrency"] : nil
      return nil unless value.to_i.positive?
      Agent::Paths.write_json(Agent::Paths.runner_file,
                              { "max_concurrency" => value.to_i, "at" => now.utc.iso8601 })
      value.to_i
    rescue StandardError
      nil
    end

    def sbt_opts
      known = concurrency
      return "-Xmx#{MIN_GB}G #{STACK}" if known.nil?
      opts(memory_bytes: memory_bytes, concurrency: known)
    end

    def env = { "SBT_OPTS" => sbt_opts }

    # ---- what the machine's own profile does to all of the above ----

    # `SBT_OPTS` as a LOGIN shell exports it, which is the environment every
    # session command and the tick itself actually get (launchd runs the tick
    # through `/bin/zsh -lc`). Resolved the same way `Agent::Toolchain.agent_path`
    # resolves PATH, and for the same reason: asking this process is asking the
    # wrong shell.
    def login_shell_sbt_opts
      result = Agent::Shell.capture("/bin/zsh", "-lc", "printf %s \"$SBT_OPTS\"",
                                    timeout: PROBE_TIMEOUT_SECONDS, stderr: :inherit)
      return nil unless result.ok?
      value = result.output.strip
      value.empty? ? nil : value
    rescue Errno::ENOENT
      nil
    end

    # The profile's value, but only when it PINS a heap — the case that silently
    # beats everything this module does. A profile that sets, say, only
    # `-Dsbt.color=always` is not a finding.
    def profile_override(value = login_shell_sbt_opts)
      value if value && PINS_HEAP.match?(value)
    end

    def explain
      gb = memory_bytes
      known = concurrency
      lines = ["sbt heap for this machine: #{sbt_opts}"]
      lines << format("  physical RAM       %s", gb ? "#{(gb.to_f / GB).round}G (hw.memsize)" : "unknown")
      lines << if known
                 "  agent slots        #{known} (max_concurrency, from the registry)"
               else
                 "  agent slots        unknown — this machine has not read its registry row yet, " \
                 "so the floor (#{MIN_GB}G) is used until the next tick"
               end
      if gb && known
        lines << format("  per-slot budget    %.1fG   (RAM / slots)", (gb.to_f / GB) / known)
        lines << "  heap               #{(SLOT_FRACTION * 100).round}% of the slot, " \
                 "clamped to [#{MIN_GB}G, #{MAX_GB}G]"
      end
      override = profile_override
      if override
        lines += ["",
                  "WARNING: this machine's login profile exports SBT_OPTS=#{override.strip.inspect}, and a",
                  "login shell re-sources it for every command — so it OVERRIDES the value above unless",
                  "sbt is run with SBT_OPTS assigned in the same shell invocation:",
                  "",
                  "  SBT_OPTS=\"$(dev agent sbt-opts)\" sbt test",
                  "",
                  "Fix the machine by making the profile a DEFAULT rather than an override:",
                  "",
                  "  export SBT_OPTS=\"${SBT_OPTS:--Xmx8G -Xss4M}\"",
                  ""]
      end
      lines.join("\n")
    end
  end
end
