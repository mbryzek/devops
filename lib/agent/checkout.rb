require 'open3'
require 'agent/paths'

# The devops checkout the tick runs out of, and how it keeps itself current.
#
# ONE PUSH TO devops REACHES THE WHOLE FLEET. Before this existed, changing a
# producer's schedule meant logging into every agent machine to pull, so the
# registry in git was the system of record in name only -- what a machine
# actually ran was whatever it had last been hand-pulled to. The tick now pulls
# its own checkout, which is what makes "producers.yml in git is the only
# registry" true in practice rather than aspirationally.
#
# THREE PROPERTIES MAKE THIS SAFE, and none of them is optional:
#
#   --ff-only     A machine whose checkout has diverged (a hand-edit, an
#                 abandoned local commit) must STOP, not merge. A merge here
#                 would silently invent a fleet-wide code state that exists in
#                 nobody's repo and in no review.
#   report, never crash
#                 The pull runs on the vitals path. A network blip, a locked
#                 index, a checkout on the wrong branch -- none of those may be
#                 allowed to take out heartbeats and the hard-timeout enforcement
#                 that Phase A exists to guarantee. A failed pull leaves the
#                 machine on its old sha and says so; the reported sha then makes
#                 it visible in admin instead of silently stale.
#   Phase A, before the work lock
#                 Never mid-job. `dev agent tick` is a one-shot process, so code
#                 changed by a pull takes effect on the NEXT tick -- the running
#                 tick has already loaded everything it will use. A daemon would
#                 have to reason about swapping code under itself; this does not.
module Agent
  module Checkout
    Result = Struct.new(:ok, :sha, :changed, :message, keyword_init: true) do
      def ok? = ok
      def changed? = changed
    end

    # Phase A is bounded by construction and this is the only thing in it that
    # talks to a network it does not control. An unbounded `git pull` that hangs
    # on a stalled fetch would hold the vitals lock, and a machine that stops
    # heartbeating reports an outage that is not happening -- the exact alarm
    # inversion the two-phase split exists to prevent. 60 seconds is ~120x a
    # normal fetch of this repo.
    PULL_TIMEOUT_SECONDS = 60

    # Nothing on the tick path may ever block on a prompt. A repo whose remote
    # asks for credentials must fail immediately and be reported, not sit there
    # waiting for a human who is not logged in.
    NON_INTERACTIVE = {
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes",
      "GIT_ASKPASS" => "/usr/bin/true",
    }.freeze

    module_function

    # The repo this very file lives in — Agent::Paths owns the resolution, so
    # producers.yml and the githooks move with whatever this pulls. Deliberately
    # derived from the running code's own location rather than from a configured
    # ~/code/devops: the tick must update the checkout it is RUNNING.
    def devops_repo = Agent::Paths.devops_repo

    def head_sha(repo = devops_repo)
      out, status = Open3.capture2e("git", "-C", repo, "rev-parse", "HEAD")
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end

    # `git pull --ff-only origin main`, with every failure mode folded into a
    # Result rather than an exception.
    def pull(repo = devops_repo)
      before = head_sha(repo)
      return Result.new(ok: false, sha: nil, changed: false, message: "#{repo} is not a git checkout") if before.nil?

      out, ok = run_bounded("git", "-C", repo, "pull", "--ff-only", "origin", "main")
      after = head_sha(repo)
      if ok
        Result.new(ok: true, sha: after, changed: after != before,
                   message: after == before ? "already at #{short(after)}" : "#{short(before)} -> #{short(after)}")
      else
        # after == before here in every case worth naming (a refused fast-forward
        # changes nothing), so the machine keeps running the code it has.
        Result.new(ok: false, sha: after, changed: false, message: first_error_line(out))
      end
    rescue Errno::ENOENT => e
      Result.new(ok: false, sha: before, changed: false, message: e.message)
    end

    # Runs a command with a hard deadline, non-interactively. Returns
    # [combined_output, ok]. A process that outlives the deadline is KILLed --
    # TERM would be politer, but a git that is wedged on a network read is
    # exactly the process that ignores it.
    def run_bounded(*cmd, timeout: PULL_TIMEOUT_SECONDS)
      Open3.popen2e(NON_INTERACTIVE, *cmd) do |stdin, out, wait_thr|
        stdin.close
        unless wait_thr.join(timeout)
          begin
            Process.kill("KILL", wait_thr.pid)
          rescue Errno::ESRCH
            nil
          end
          wait_thr.join
          next ["fatal: timed out after #{timeout}s", false]
        end
        [out.read, wait_thr.value.success?]
      end
    end

    def short(sha) = sha.to_s[0, 8]

    # git's own diagnosis, one line of it. The full transcript goes nowhere
    # useful in a tick log that a human skims for the one line that matters.
    def first_error_line(output)
      lines = output.to_s.lines.map(&:strip).reject(&:empty?)
      lines.find { |l| l.start_with?("fatal:", "error:") } || lines.last || "git pull failed"
    end
  end
end
