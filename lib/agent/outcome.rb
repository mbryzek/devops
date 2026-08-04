# Outcome classification (design §4.4).
#
# MECHANICAL, NEVER INFERRED FROM CLAUDE'S PROSE. Four signals, in order:
#
#   1. a PR the session left behind, and its state: merged, open-ready, or draft
#   2. new commits under ~/code/claude/plans/
#   3. whether the tick itself killed this session, and why
#   4. the process exit code
#
# The session's own words are not one of them. A session that says "I opened a
# PR" and did not, or that summarizes a failure as a success, must not be able
# to move the issue — which is why the branch name is assigned by the executor
# and recorded on the lease, so this check is a lookup and not a search.
#
# Signal 3 is knowledge only the executor has. When the tick kills a session it
# destroys the very artifacts the other signals read: no exit code gets written,
# claude.log stops mid-sentence. Re-deriving "what happened" from what a kill
# prevented from being written is how a killed session came to be reported as
# having completed with nothing to do (ISS-364). The killer records what it did
# on the job record and classification reads it back.
#
# Pure: every input is passed in and nothing here shells out. `Agent::Github`
# is required only for its PR-state predicates, which are plain functions over
# the hash it produced; the tick gathers the signals.
require 'agent/github'

module Agent
  module Outcome
    # `status` is the issue status to move to; `lease_outcome` closes the lease.
    Result = Struct.new(:name, :status, :lease_outcome, :reason, :url, keyword_init: true)

    # Give up after this many lease rows for one issue. The lease table IS the
    # attempt history (one row per attempt), so no counter column exists.
    MAX_ATTEMPTS = 3

    # Why the tick killed a session, in the words the post-mortem needs. Keyed by
    # what `Agent::Jobs.mark_killed` records.
    KILL_REASONS = {
      "lease_lost" => "Session was KILLED by the tick: its lease expired or was reassigned (409), " \
                      "so nothing it was doing could be trusted to still be its work",
      "timeout" => "Session was KILLED by the tick after exceeding its hard timeout",
    }.freeze

    module_function

    # pr:              nil, or { "url" => ..., "isDraft" => ..., "state" => "MERGED"|"OPEN"|"CLOSED" }
    # plans_committed: did the session land new commits under ~/code/claude/plans/?
    # killed:          nil, or the tick's own record of killing it ({ "reason" => ... })
    # exit_code:       the reaped process's exit status (nil if it never wrote one)
    # timed_out:       did Phase A kill it on the 4-hour hard timeout?
    # producer_filed:  was this issue filed by a producer rather than a human?
    # attempt:         how many leases this issue has had, including this one
    def classify(pr:, plans_committed:, exit_code:, producer_filed:, attempt: 1, timed_out: false, killed: nil)
      # A MERGED PR outranks every other signal, including a kill and a non-zero
      # exit. It is the strongest possible evidence the work landed, and until
      # ISS-364 it was the one case that read as failure: classification looked
      # only for an OPEN PR, so a PR reviewed and merged in the 71 seconds before
      # the reap looked exactly like a session that did nothing, and the issue was
      # DISMISSED with its fix on main.
      if Agent::Github.merged?(pr)
        return Result.new(name: "merged_pr", status: "fixed", lease_outcome: "succeeded",
                          reason: "Merged PR #{pr['url']}", url: pr["url"])
      end

      if Agent::Github.ready?(pr)
        return Result.new(name: "ready_pr", status: "fixed", lease_outcome: "succeeded",
                          reason: "Ready PR #{pr['url']}", url: pr["url"])
      end

      if plans_committed
        return Result.new(name: "design_document", status: "needs_review", lease_outcome: "succeeded",
                          reason: "Design document committed under ~/code/claude/plans/")
      end

      # Only now, with no delivered artifact to protect, does the kill decide —
      # and it decides over the exit code, which a killed wrapper never wrote.
      # `failure` returns the issue to the queue: a killed attempt needs
      # RE-RUNNING, not a human's input.
      if killed
        return failure(killed_reason(killed), attempt, url: pr && pr["url"])
      end

      # A draft PR is unfinished work, not a result: the session opened it and
      # never marked it ready. Retryable, and the retry resumes THIS branch and
      # updates the same PR in place (§4.4.1) rather than opening a second one.
      if Agent::Github.draft?(pr)
        return failure("Draft PR left open at #{pr['url']} — never marked ready for review", attempt, url: pr["url"])
      end

      return failure("Session hit the hard timeout and was killed", attempt) if timed_out

      # An ABSENT exit code is never a clean exit: the wrapper writes it with
      # `echo $? > exit_code` as its last act, so no file means the process was
      # killed or the machine went down under it. `nil.to_i` is 0, which is
      # exactly how that used to read as "completed with nothing to do".
      return failure("Session left no exit code — it was killed or the machine went down before it finished", attempt) if exit_code.nil?
      return failure("Session exited #{exit_code} with no PR and no plan", attempt) unless exit_code.zero?

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

    # The kill record's own words. An unrecognized reason is still reported as a
    # kill — the post-mortem must never lose the fact that the tick did this.
    def killed_reason(killed)
      reason = (killed.is_a?(Hash) ? killed["reason"] : killed).to_s
      KILL_REASONS.fetch(reason) do
        "Session was KILLED by the tick (#{reason.empty? ? 'reason not recorded' : reason})"
      end
    end

    # Workspaces are deleted on success and kept for the post-mortem window
    # otherwise (design §4.3.1).
    def success?(result)
      %w[merged_pr ready_pr design_document nothing_to_do].include?(result.name)
    end
  end
end
