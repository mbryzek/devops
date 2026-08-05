require 'open3'
require 'agent/paths'

# The devops checkout the tick runs out of, and how it keeps itself current.
#
# ONE PUSH TO devops REACHES THE WHOLE FLEET. Before this existed, changing a
# producer's schedule meant logging into every agent machine to pull, so the
# registry in git was the system of record in name only -- what a machine
# actually ran was whatever it had last been hand-pulled to. The tick now pulls
# its own checkout, which is what makes "the standing prompt in git is the only
# registry" true in practice rather than aspirationally.
#
# THREE PROPERTIES MAKE THIS SAFE, and none of them is optional:
#
#   --ff-only     A machine whose checkout has diverged must STOP, not merge. A
#                 merge here would silently invent a fleet-wide code state that
#                 exists in nobody's repo and in no review. A DIRTY tree or a
#                 checkout on a branch other than main is left completely
#                 alone -- that is Mike (or a claimed session) doing
#                 interactive work in this exact checkout, and `pull` reports
#                 it as a benign skip rather than touching anything. A CLEAN
#                 checkout on main that still refuses to fast-forward has no
#                 local explanation left, so `pull` allows itself exactly one
#                 `fetch` + `reset --hard origin/main` to recover from rewritten
#                 upstream history before calling it a real failure.
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
    # `benign` marks a failed pull that is NOT this module's problem to report:
    # the checkout is dirty, or on a branch other than main, which means a
    # human is doing interactive work in it right here. Only a non-benign
    # (`ok: false, benign: false`) result is a real failure worth escalating —
    # see Agent::Tick#update_checkout.
    Result = Struct.new(:ok, :sha, :changed, :message, :benign, keyword_init: true) do
      def ok? = ok
      def changed? = changed
      def benign? = benign
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

    # The repo this very file lives in — Agent::Paths owns the resolution, so the
    # standing prompt and the githooks move with whatever this pulls. Deliberately
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
    #
    # A refused fast-forward has two, very different causes, and conflating
    # them would either bulldoze a human's work or silently leave the fleet
    # stuck forever:
    #
    #   DIRTY, or not on main   Mike (or a claimed session) is doing
    #                           interactive work in this exact checkout. NEVER
    #                           touch it — return `benign: true` and stop.
    #   CLEAN, on main          Nothing local explains the refusal, so the only
    #                           remaining cause is upstream history that no
    #                           longer fast-forwards from here (a rebase, a
    #                           force-push). One shot at `fetch` + `reset
    #                           --hard origin/main` recovers automatically;
    #                           if even that fails, it's a real failure.
    def pull(repo = devops_repo)
      before = head_sha(repo)
      return Result.new(ok: false, sha: nil, changed: false, benign: false, message: "#{repo} is not a git checkout") if before.nil?

      out, ok = run_bounded("git", "-C", repo, "pull", "--ff-only", "origin", "main")
      after = head_sha(repo)
      return Result.new(ok: true, sha: after, changed: after != before, benign: false,
                        message: after == before ? "already at #{short(after)}" : "#{short(before)} -> #{short(after)}") if ok

      if dirty?(repo) || current_branch(repo) != "main"
        # after == before here in every case worth naming (a refused
        # fast-forward changes nothing), so the machine keeps running the code
        # it has, and this checkout is left exactly as the human left it.
        return Result.new(ok: false, sha: after, changed: false, benign: true, message: first_error_line(out))
      end

      if reset_to_origin(repo)
        recovered = head_sha(repo)
        Result.new(ok: true, sha: recovered, changed: recovered != before, benign: false,
                   message: "recovered via fetch + reset --hard: #{short(before)} -> #{short(recovered)}")
      else
        Result.new(ok: false, sha: head_sha(repo), changed: false, benign: false, message: first_error_line(out))
      end
    rescue Errno::ENOENT => e
      Result.new(ok: false, sha: before, changed: false, benign: false, message: e.message)
    end

    # True when the working tree has any local changes — staged, unstaged, or
    # untracked. A `git status` that itself fails is treated as dirty: "cannot
    # tell" must never be the reason a hard reset runs.
    def dirty?(repo)
      out, status = Open3.capture2e("git", "-C", repo, "status", "--porcelain")
      !status.success? || !out.strip.empty?
    rescue Errno::ENOENT
      true
    end

    def current_branch(repo)
      out, status = Open3.capture2e("git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD")
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end

    # The one fallback this module ever runs, and only reachable once the
    # caller has proven the tree is clean and on main (see `pull`). Fetch,
    # then reset — two bounded calls, never a bare `git pull` retried, so a
    # fetch that succeeds but a reset that fails still leaves an accurate sha
    # for the caller to read back.
    def reset_to_origin(repo)
      _out, fetch_ok = run_bounded("git", "-C", repo, "fetch", "origin", "main")
      return false unless fetch_ok
      _out, reset_ok = run_bounded("git", "-C", repo, "reset", "--hard", "origin/main")
      reset_ok
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
