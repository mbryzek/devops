# Outcome classification (design §4.4).
#
# MECHANICAL, NEVER INFERRED FROM CLAUDE'S PROSE. Three signals, in order:
#
#   1. an open PR on the branch the executor assigned, and whether it is a draft
#   2. new commits under ~/code/claude/plans/
#   3. the process exit code
#
# The session's own words are not one of them. A session that says "I opened a
# PR" and did not, or that summarizes a failure as a success, must not be able
# to move the issue — which is why the branch name is assigned by the executor
# and recorded on the lease, so this check is a lookup and not a search.
#
# Pure: every input is passed in, nothing here shells out. `Agent::Reaper`
# gathers the signals.
module Agent
  module Outcome
    # `status` is the issue status to move to; `lease_outcome` closes the lease.
    Result = Struct.new(:name, :status, :lease_outcome, :reason, :url, keyword_init: true)

    # Give up after this many lease rows for one issue. The lease table IS the
    # attempt history (one row per attempt), so no counter column exists.
    MAX_ATTEMPTS = 3

    module_function

    # pr:              nil, or { "url" => ..., "isDraft" => true/false }
    # plans_committed: did the session land new commits under ~/code/claude/plans/?
    # exit_code:       the reaped process's exit status (nil if it was killed)
    # timed_out:       did Phase A kill it on the 4-hour hard timeout?
    # producer_filed:  was this issue filed by a producer rather than a human?
    # attempt:         how many leases this issue has had, including this one
    def classify(pr:, plans_committed:, exit_code:, producer_filed:, attempt: 1, timed_out: false)
      if pr && !pr["isDraft"]
        return Result.new(name: "ready_pr", status: "fixed", lease_outcome: "succeeded",
                          reason: "Ready PR #{pr['url']}", url: pr["url"])
      end

      if plans_committed
        return Result.new(name: "design_document", status: "needs_review", lease_outcome: "succeeded",
                          reason: "Design document committed under ~/code/claude/plans/")
      end

      # A draft PR is unfinished work, not a result: the session opened it and
      # never marked it ready. Retryable, and the retry resumes THIS branch and
      # updates the same PR in place (§4.4.1) rather than opening a second one.
      if pr
        return failure("Draft PR left open at #{pr['url']} — never marked ready for review", attempt, url: pr["url"])
      end

      return failure("Session hit the hard timeout and was killed", attempt) if timed_out
      return failure("Session exited #{exit_code} with no PR and no plan", attempt) unless exit_code.to_i.zero?

      # Clean exit, nothing produced. Who filed the issue decides where it lands,
      # and this is the asymmetry that matters: an agent finding "nothing wrong"
      # with a bug a HUMAN filed is more often wrong than right, so it states
      # what it checked and a human decides. Agents never self-dismiss
      # human-filed work. A producer re-files if the condition recurs, so
      # dismissing its own issue is safe.
      if producer_filed
        Result.new(name: "nothing_to_do", status: "dismissed", lease_outcome: "succeeded",
                   reason: "Producer-filed issue: session completed with nothing to do")
      else
        Result.new(name: "nothing_to_do", status: "needs_input", lease_outcome: "succeeded",
                   reason: "Session completed without opening a PR or writing a plan. " \
                           "A human-authored issue is never auto-dismissed — see the session log for what was checked.")
      end
    end

    # A retryable failure returns the issue to `open` (the sweeper applies the
    # snoozed_until backoff server-side); the attempt limit converts it to a
    # question for a human rather than an issue that ages silently.
    def failure(reason, attempt, url: nil)
      if attempt >= MAX_ATTEMPTS
        Result.new(name: "gave_up", status: "needs_input", lease_outcome: "failed", url: url,
                   reason: "#{reason}. Attempt #{attempt} of #{MAX_ATTEMPTS} — giving up and asking for input.")
      else
        Result.new(name: "failed", status: "open", lease_outcome: "failed", url: url,
                   reason: "#{reason}. Attempt #{attempt} of #{MAX_ATTEMPTS} — returning to the queue.")
      end
    end

    # Workspaces are deleted on success and kept for the post-mortem window
    # otherwise (design §4.3.1).
    def success?(result)
      %w[ready_pr design_document nothing_to_do].include?(result.name)
    end
  end
end
