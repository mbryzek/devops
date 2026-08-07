require 'open3'

# Every subprocess the dispatcher runs, with a deadline on it (ISS-740).
#
# WHY THIS EXISTS. `dev agent tick` is a one-shot process that runs every 30
# seconds, and each phase is guarded by a lock so two ticks cannot do the same
# work at once. A subprocess that HANGS therefore does not fail — it holds that
# lock forever, and every later tick finds it held and skips. The machine keeps
# heartbeating, keeps looking healthy, and never claims another issue. Nothing
# logs an error, because a hang is not an exception.
#
# The failure is not hypothetical and the candidates are ordinary: `docker
# --version` against a wedged daemon, `sbt --script-version` blocking on a
# network-backed launcher, `docker prune` under exactly the disk pressure the
# prune exists to relieve, `gh pr list` against a stalled connection, `git pull`
# on a hung fetch. Agent::Checkout got a deadline for the last of those and
# wrote down the reasoning (PULL_TIMEOUT_SECONDS: "a machine that stops
# heartbeating reports an outage that is not happening"); Agent::Workspace got
# one for clones. Everything else in lib/agent shelled out unbounded.
#
# So this is that helper, extracted, and it is the ONLY thing in lib/agent that
# may call Open3 — test_dev_agent_shell.rb asserts that by scanning the
# directory, so a new call site cannot reintroduce an unbounded subprocess
# without the suite failing. A timeout that has to be remembered is a timeout
# that gets forgotten once and wedges a runner for a week.
#
# THREE PROPERTIES, and none is incidental:
#
#   read while you wait   Output is drained on its own thread rather than after
#                         the wait. A command that writes more than the ~64KB
#                         pipe buffer blocks on write until someone reads, so a
#                         join-then-read helper would time out and KILL any
#                         chatty command — `docker prune --apply` listing every
#                         image it removed is precisely that. `capture2e` reads
#                         concurrently for this reason; a naive popen2e wrapper
#                         silently loses the property.
#   kill the GROUP        The child is spawned as its own process-group leader
#                         and the group is what gets killed. `dev docker prune`
#                         is a Ruby process that shells out to `docker`; killing
#                         only the Ruby leaves the wedged docker running and
#                         holding the pipe, which is the same hang one level
#                         down.
#   KILL, not TERM        TERM is politer and a process wedged on an
#                         uninterruptible read is exactly the process that
#                         ignores it. This runs unattended; "asked nicely and
#                         waited" is how the lock stays held.
module Agent
  module Shell
    # A deliberately unhelpful default: every call site names its own timeout,
    # because the right bound for `--version` (seconds) and for a full `docker
    # prune` (minutes) differ by two orders of magnitude and a shared number
    # would be wrong for both. This exists only so a `capture` with no timeout is
    # bounded rather than a syntax error waiting to be discovered in production.
    DEFAULT_TIMEOUT_SECONDS = 60

    # How long to wait for the output pipe to close after the child is killed.
    # Bounded for the same reason everything here is: a grandchild that survived
    # the group kill and inherited stdout would otherwise hold this thread — and
    # therefore the tick — open forever, which is the bug rather than the fix.
    DRAIN_SECONDS = 5

    # `status` is nil exactly when the command timed out: there is no exit status
    # for a process we killed, and reporting one (137, say) would let a caller
    # mistake a deadline for the command's own answer.
    Result = Struct.new(:output, :status, :timed_out, :timeout, keyword_init: true) do
      def ok? = !timed_out && !status.nil? && status.success?
      def timed_out? = !!timed_out
      def exitstatus = status&.exitstatus

      # The half of a failure message that says WHAT went wrong, for callers that
      # build their own operator-facing line around it.
      def summary = timed_out? ? "timed out after #{timeout}s" : "exited #{exitstatus}"
    end

    module_function

    # Runs `cmd` with a hard deadline and returns a Result. Raises
    # Errno::ENOENT (a SystemCallError) when the binary does not exist, exactly
    # as Open3 does — "not installed" and "ran and failed" are different facts
    # and every caller here distinguishes them.
    #
    # `stderr:` is `:merge` (combined into `output`, at the fd level, so
    # interleaving is preserved) or `:inherit` (left on the parent's stderr and
    # NOT captured). `:inherit` exists for the one caller that parses stdout —
    # Toolchain.agent_path reads `$PATH` out of a login shell, and a .zprofile
    # that prints a warning would otherwise be spliced into the PATH the whole
    # doctor then scans.
    def capture(*cmd, timeout: DEFAULT_TIMEOUT_SECONDS, env: {}, chdir: nil, stderr: :merge)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir
      opener = stderr == :merge ? Open3.method(:popen2e) : Open3.method(:popen2)
      opener.call(env, *cmd, **opts) do |stdin, out, wait_thr|
        stdin.close
        reader = Thread.new { out.read }
        if wait_thr.join(timeout)
          Result.new(output: drain(reader), status: wait_thr.value, timed_out: false, timeout: timeout)
        else
          terminate(wait_thr.pid)
          wait_thr.join
          Result.new(output: drain(reader), status: nil, timed_out: true, timeout: timeout)
        end
      end
    end

    # Whatever the command managed to say before its deadline. A killed process's
    # partial output is usually the whole diagnosis ("Cannot connect to the
    # Docker daemon" and then nothing), so it is kept rather than discarded.
    def drain(reader)
      return reader.value if reader.join(DRAIN_SECONDS)
      reader.kill
      ""
    end

    # The negative pid is the process GROUP, which is why `pgroup: true` above is
    # load-bearing: without it this would signal the tick's own group. ESRCH is
    # the child exiting in the gap between the deadline and the signal — a race
    # this is allowed to lose, since the join below then returns immediately.
    def terminate(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
