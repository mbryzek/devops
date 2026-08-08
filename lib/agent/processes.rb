require 'etc'
require 'set'
require 'agent/redact'
require 'agent/shell'

# The processes an agent session leaves behind, and the two facts about this
# machine that explain why a session felt slow (ISS-782).
#
# WHY THIS EXISTS. `Agent::Jobs.kill` signals the process GROUP, and its comment
# says that is "because the session spawns sbt, docker and gh children of its
# own and killing only the leader would leave a 12G sbt JVM behind". That
# premise is false, and had been since the day it was written. `spawn_session`
# puts the wrapper in its own group (`pgroup: true`), so the wrapper and the
# `claude` CLI share a group — but the Claude CLI runs EVERY Bash tool call in a
# NEW process group of its own, so nothing a session actually spawns is in the
# group the executor knows about:
#
#   pid 6734  ppid 1     pgid 6734   /bin/sh -c claude --print ...   <- signalled
#   pid 6735  ppid 6734  pgid 6734   claude --print ...              <- signalled
#   pid 7871  ppid 6735  pgid 7871   /bin/zsh -c source ...snapshot  <- NOT
#
# So killing a timed-out session has never reached its sbt, its docker CLI, or
# anything else it started. What it reaches is the CLI, and everything below
# that reparents to init and keeps running.
#
# That is how twenty `while :; do :; done` subshells — a session's own synthetic
# CPU load, built to test whether a hang was starvation, whose trailing
# `kill $HOGS` was never reached because the tool call died first — sat at ~48%
# CPU each for thirteen hours on a ten-core Mac mini, holding the load average
# near 50 while later sessions competed with them at the same nice level.
#
# TWO ANSWERS, because they cover different failures:
#
#   descendants  the tree, walked from a live session's pid. Used by the KILL
#                path, where parentage still proves descent. Exact.
#   leaked       groups whose session is provably gone, found from `ps` alone.
#                Used by the hourly maintenance sweep, for everything the kill
#                path never saw: a tick that died before it reaped, a machine
#                whose agent was unloaded, a session that exited on its own —
#                which is the common case, because `reap` only ever looks at a
#                job whose leader is ALREADY dead and never signalled anything.
module Agent
  module Processes
    # One row of `ps`. `cpu_seconds` is accumulated CPU time and `elapsed_seconds`
    # is wall-clock age; the pair is what distinguishes a runaway (they track each
    # other) from something merely long-lived (cpu far below elapsed).
    Entry = Struct.new(:pid, :ppid, :pgid, :elapsed_seconds, :cpu_seconds, :command,
                       keyword_init: true) do
      def orphan? = ppid == 1
    end

    # A Claude Bash tool call, as the CLI spawns it. Every tool call sources the
    # session's shell snapshot, and nothing else on the machine has this shape —
    # which is what makes it safe to use as the proof that a process group was
    # created by an agent session rather than by a human's shell.
    #
    # Matching the SHELL also catches the subshells it forks: a `( ... ) &` never
    # execs, so it keeps its parent's command line verbatim in `ps`.
    #
    # Deliberately loose about everything between the two anchors. The exact
    # preamble is the CLI's private business — today it is
    # `-c source <snap> 2>/dev/null || true && setopt ... && eval '...'`, and it
    # has no reason to stay that way across an upgrade. What this pins is only
    # what must be true for the process to BE a tool call: a shell, running
    # something that references the session's snapshot directory. A tighter
    # pattern would fail in the worst available way — it would stop matching, the
    # sweep would find nothing, and a runner buried under leaked processes would
    # report exactly what a clean one does.
    TOOL_SHELL = %r{\A\S*/(?:ba|z|d|k)?sh\b.*/\.claude/shell-snapshots/}.freeze

    # A live `claude` CLI, or the `sh -c` wrapper the executor spawns it under.
    # `claude` has to be a whole whitespace-delimited token here, which is what
    # keeps two near-misses out: `claude-db gc` is a different binary, and the
    # snapshot PATH inside every TOOL_SHELL command contains `/.claude/` and would
    # otherwise make every tool call look like a live session.
    CLAUDE_SESSION = %r{(?:\A|\s)(?:\S*/)?claude(?:\s|\z)}.freeze

    # A leaked group has to be this old before the sweep will touch it. The
    # predicate below is already a proof rather than a heuristic, so this is not
    # buying confidence in the verdict — it is refusing to race a session that is
    # in the middle of exiting right now, where a child can briefly show ppid 1
    # while its siblings are still tearing down. Five minutes is far outside that
    # window and far inside the hourly cadence that calls this.
    MIN_LEAK_AGE_SECONDS = 300

    module_function

    # ---- reading ----

    # `-U` so this only ever sees the agent user's own processes, never root's
    # and never another login's. `command=` last, because it is the one field
    # that contains spaces.
    PS_FORMAT = "pid=,ppid=,pgid=,etime=,time=,command=".freeze

    # The NUMERIC uid, not `Etc.getlogin` and not `$USER`. Under launchd — which
    # is how the tick actually runs — `getlogin` answers "root" on this machine
    # even in a process running as athena, so a sweep keyed on it silently
    # examined root's 136 processes instead of the agent's 542 and found no leak
    # it was looking for. A uid cannot be wrong about itself.
    def read(user: Process.uid)
      result = Agent::Shell.capture("ps", "-U", user.to_s, "-o", PS_FORMAT, timeout: 10)
      return [] unless result.ok?
      parse(result.output)
    rescue SystemCallError
      []
    end

    # `command` is REDACTED on the way in, so `Entry#command` is never a secret
    # carrier anywhere downstream (ISS-961).
    #
    # A command line is public on these runners: `ps -U <uid>` shows every
    # argument of every process the agent user owns, to every other process it
    # owns, and three agent sessions share one Mac mini. `PS_FORMAT` above asks
    # for `command=` precisely so this module can read those lines — which makes
    # every Entry a copy of whatever credential a sibling session inlined into a
    # command, held in a public struct field.
    #
    # Nothing prints one today. That is the reason to do it here rather than at
    # the eventual call site: the obvious next improvement to the sweep is to SAY
    # which processes it reaped, and the person writing that line should not have
    # to know this hazard exists. Redacting at the boundary means they cannot
    # leak, whatever they print.
    #
    # `Agent::Redact` is shape-preserving, so TOOL_SHELL, CLAUDE_SESSION and the
    # whole `leaked?` predicate below still see the structure they match on —
    # asserted in test_dev_agent_redact.rb, because a sweep that silently stopped
    # matching would report a buried runner as a clean one.
    def parse(output)
      output.to_s.lines.filter_map do |line|
        pid, ppid, pgid, etime, time, command = line.strip.split(/\s+/, 6)
        next if command.nil? || pid !~ /\A\d+\z/
        Entry.new(pid: pid.to_i, ppid: ppid.to_i, pgid: pgid.to_i,
                  elapsed_seconds: duration(etime), cpu_seconds: duration(time),
                  command: Agent::Redact.command(command))
      end
    end

    # `[[dd-]hh:]mm:ss[.ff]`, which covers both `etime` and `time`. Returns 0.0
    # rather than nil for anything unparseable: every caller compares against a
    # floor, and a nil there would either raise or silently pass the floor.
    def duration(text)
      return 0.0 if text.nil?
      days, _, rest = text.rpartition("-")
      parts = rest.split(":")
      return 0.0 if parts.empty? || parts.any? { |p| p !~ /\A\d+(\.\d+)?\z/ }
      seconds = parts.reverse.each_with_index.sum { |p, i| p.to_f * (60**i) }
      seconds + (days.empty? ? 0 : days.to_i * 86_400)
    end

    # ---- the kill path ----

    # Every process below `pid`, transitively, nearest-last so a caller signalling
    # in order takes the leaves before their parents. Excludes `pid` itself: the
    # caller signals the session leader through its own group, and a walk that
    # included it would be one bad ppid away from returning the whole machine.
    # `seen` starts holding the root pid, so the walk can never return the
    # process it started from. Real ppids are acyclic — every chain ends at init
    # — but this is the input to a SIGKILL loop running inside the tick, and the
    # cost of the guard is one Set entry against a caller that would otherwise
    # signal the session leader twice, or in the cyclic case signal itself.
    def descendants(pid, procs = read)
      root = pid.to_i
      children = procs.group_by(&:ppid)
      seen = Set[root]
      out = []
      queue = Array(children[root]).dup
      until queue.empty?
        current = queue.shift
        next unless seen.add?(current.pid)
        out << current
        queue.concat(Array(children[current.pid]))
      end
      out.reverse
    end

    # ---- the sweep ----

    # Process groups that no live session can still reach. Every one of these has
    # to hold, and each rules out a specific way of being wrong:
    #
    #   shape     some member is a Claude Bash tool call, so the group was
    #             created by an agent session and not by a human's shell.
    #   no claude no member is a live `claude` or its wrapper. The executor
    #             spawns that wrapper DETACHED, so a perfectly healthy running
    #             session is also a group rooted at init (pid 6734 ppid 1 above)
    #             and would otherwise satisfy every other clause here.
    #   rooted    every member's parent is init or another member. This is the
    #             one that proves ABANDONMENT: a live session's tool call has the
    #             `claude` process as its parent, so any group something outside
    #             it still owns fails here — including a backgrounded tool call
    #             the session is deliberately still using.
    #   age       older than MIN_LEAK_AGE_SECONDS.
    #
    # Deliberately NOT a CPU-time threshold, which is what the issue proposed. The
    # clauses above are a proof that nothing can ever use these processes again,
    # and once that holds an idle leak is as collectable as a spinning one — while
    # a CPU floor would leave the idle ones accumulating forever and would be the
    # only clause here that could be wrong about a process doing real work.
    def leaked(procs = read, min_age: MIN_LEAK_AGE_SECONDS)
      procs.group_by(&:pgid).values.select { |members| leaked?(members, min_age) }
    end

    def leaked?(members, min_age = MIN_LEAK_AGE_SECONDS)
      return false unless members.any? { |p| p.command.match?(TOOL_SHELL) }
      return false if members.any? { |p| p.command.match?(CLAUDE_SESSION) }
      pids = members.map(&:pid).to_set
      return false unless members.all? { |p| p.ppid == 1 || pids.include?(p.ppid) }
      members.all? { |p| p.elapsed_seconds >= min_age }
    end

    # ---- signalling ----

    def alive?(pid)
      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM, TypeError
      false
    end

    def signal(pids, name)
      Array(pids).each do |pid|
        next if pid.to_i == Process.pid
        begin
          Process.kill(name, pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    # SIGTERM, a grace period, then SIGKILL to whatever is left. Returns the pids
    # that were still alive when the grace ran out, so a caller can say what it
    # had to force.
    #
    # Never signals this process, which matters more here than it looks: the
    # sweep runs INSIDE the tick, and a bad ppid in `descendants` that walked up
    # instead of down would otherwise have the tick kill itself.
    def terminate(pids, grace: 10)
      pids = Array(pids).map(&:to_i).reject { |pid| pid == Process.pid }
      signal(pids, "TERM")
      deadline = Time.now + grace
      sleep(0.2) while pids.any? { |pid| alive?(pid) } && Time.now < deadline
      forced = pids.select { |pid| alive?(pid) }
      signal(forced, "KILL")
      forced
    end

    # ---- load ----

    # [1m, 5m, 15m], or nil when the machine will not say. `sysctl` rather than
    # parsing `uptime`, whose wording differs across platforms and locales.
    def load_average
      result = Agent::Shell.capture("sysctl", "-n", "vm.loadavg", timeout: 5)
      return nil unless result.ok?
      values = result.output.scan(/\d+\.\d+/).first(3).map(&:to_f)
      values.length == 3 ? values : nil
    rescue SystemCallError
      nil
    end

    def cpu_count
      result = Agent::Shell.capture("sysctl", "-n", "hw.ncpu", timeout: 5)
      count = result.ok? ? result.output.strip.to_i : 0
      count.positive? ? count : nil
    rescue SystemCallError
      nil
    end

    # Load per core, which is the number that means something: 20 is healthy on a
    # 64-core box and catastrophic on a Mac mini. `nil` when either half is
    # unknown, never a guess.
    def load_per_cpu(load = load_average, cpus = cpu_count)
      return nil if load.nil? || cpus.nil?
      load.first / cpus
    end

    # Above this, a session's commands are competing for a core rather than
    # getting one, and "my command is wedged" and "this machine is oversubscribed"
    # stop being distinguishable from inside the session — which is the hour
    # ISS-780 lost before proving its hang was a real bug and not starvation.
    OVERSUBSCRIBED_PER_CPU = 1.5
  end
end
