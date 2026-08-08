# Outcome classification (design §4.4).
#
# MECHANICAL, NEVER INFERRED FROM CLAUDE'S PROSE. Five signals, in order:
#
#   1. a PR the session left behind, and its state: merged, open-ready, or draft
#   2. new commits under ~/code/claude/plans/
#   3. whether the tick itself killed this session, and why
#   4. the operations `dev agent run-op` executed, and what each one reported
#   5. the process exit code
#   6. whether the API refused to start the session at all (ISS-1129)
#
# The session's own words are not one of them. A session that says "I opened a
# PR" and did not, or that summarizes a failure as a success, must not be able
# to move the issue — which is why the branch name is assigned by the executor
# and recorded on the lease, so this check is a lookup and not a search.
#
# Signal 3 is knowledge only the executor has. When the tick kills a session it
# destroys the very artifacts the other signals read: no exit code gets written,
# the session log stops mid-sentence. Re-deriving "what happened" from what a kill
# prevented from being written is how a killed session came to be reported as
# having completed with nothing to do (ISS-364). The killer records what it did
# on the job record and classification reads it back.
#
# Signal 4 is the newest and the reason ISS-815 exists. Signals 1 and 2 are both
# CODE CHANGES, so a session whose job is to RUN something — `dev features
# reconcile --apply`, `api publish` — delivered its whole result and still fell
# through to `nothing_to_do`. It stays mechanical the same way the others do:
# the record is written by the OPERATION's exit status and the OPERATION's own
# output, not by the session's account of them (see Agent::Ops).
#
# Pure: every input is passed in and nothing here shells out. `Agent::Github`
# and `Agent::Ops` are required only for their predicates, which are plain
# functions over records those modules produced, and `Agent::Stream` only for
# the status code it names; the tick gathers the signals.
require 'agent/github'
require 'agent/ops'
require 'agent/stream'

module Agent
  module Outcome
    # `status` is the issue status to move to; `lease_outcome` closes the lease
    # and must be one of the platform's `issue_lease_outcome` values.
    Result = Struct.new(:name, :status, :lease_outcome, :reason, :url, keyword_init: true)

    # Give up after this many failures IN A ROW, not after this many leases.
    #
    # It used to be leases, and the name said so (ISS-734). The lease table is
    # the attempt history, but an ordinary lifetime accumulates leases that
    # failed at nothing — an issue reopened for a regression, reclaimed, handed
    # back — so counting rows made an issue give up on its FIRST real failure and
    # land in `needs_input`, which `dev issues claim` never offers. That is not a
    # stricter retry policy: it is an issue no runner can pick up again until a
    # human clears it by hand. `attempt_number` below counts the trailing run.
    GIVE_UP_AFTER_FAILURES = 3

    # How a lease ends when the attempt ENDED BADLY and the next one is a RETRY:
    # the session ran and delivered nothing (`failed`), the tick killed it
    # (`cancelled`), or nobody was ever there to report back (`expired`, written
    # by the platform's own sweeper).
    #
    # Every OTHER closed outcome ends the run, because every one of them means
    # this issue got a clean answer on that attempt: `completed` is a delivered
    # artifact, and `released` is a deliberate hand-back (a drain on pause, an
    # operator freeing a stuck lease) that nobody failed at. A live lease —
    # outcome absent — neither counts nor resets: it has not ended yet.
    FAILED_LEASE_OUTCOMES = %w[failed cancelled expired].freeze

    # Why the tick killed a session, in the words the post-mortem needs. Keyed by
    # what `Agent::Jobs.mark_killed` records.
    KILL_REASONS = {
      "lease_lost" => "Session was KILLED by the tick: its lease expired or was reassigned (409), " \
                      "so nothing it was doing could be trusted to still be its work",
      "timeout" => "Session was KILLED by the tick after exceeding its hard timeout",
    }.freeze

    module_function

    # How many failures in a row this attempt would be, from the issue's lease
    # history, oldest first. `lease_id` is THIS attempt's lease: it is excluded
    # and then counted as the +1, so a lease the sweeper closed as `expired` out
    # from under a session the reap is classifying right now is counted once and
    # not twice.
    #
    # Only leases that have ENDED are read. The trailing run stops at the first
    # one that ended well, which is what makes an ordinary released-then-failed
    # history read as "failure 1 of 3" rather than "attempt 3 of 3" (ISS-734).
    def attempt_number(lease_history, lease_id: nil)
      closed = lease_history.reject { |lease| lease["id"] == lease_id || lease["outcome"].to_s.empty? }
      closed.reverse.take_while { |lease| FAILED_LEASE_OUTCOMES.include?(lease["outcome"]) }.length + 1
    end

    # pr:              nil, or { "url" => ..., "isDraft" => ..., "state" => "MERGED"|"OPEN"|"CLOSED" }
    # plans_committed: did the session land new commits under ~/code/claude/plans/?
    # killed:          nil, or the tick's own record of killing it ({ "reason" => ... })
    # operations:      Agent::Ops::Records THIS attempt wrote, oldest first
    # exit_code:       the reaped process's exit status (nil if it never wrote one)
    # timed_out:       did Phase A kill it on the 4-hour hard timeout?
    # producer_filed:  was this issue filed by a producer rather than a human?
    # attempt:         which consecutive failure this one would be — `attempt_number`
    # usage_limit:     nil, or Agent::Stream.usage_limit's record of the API
    #                  refusing this session ({ "message" =>, "resets_at" => })
    def classify(pr:, plans_committed:, exit_code:, producer_filed:, attempt: 1, timed_out: false, killed: nil,
                 operations: [], usage_limit: nil)
      # A MERGED PR outranks every other signal, including a kill and a non-zero
      # exit. It is the strongest possible evidence the work landed, and until
      # ISS-364 it was the one case that read as failure: classification looked
      # only for an OPEN PR, so a PR reviewed and merged in the 71 seconds before
      # the reap looked exactly like a session that did nothing, and the issue was
      # DISMISSED with its fix on main.
      if Agent::Github.merged?(pr)
        return Result.new(name: "merged_pr", status: "fixed", lease_outcome: "completed",
                          reason: "Merged PR #{pr['url']}", url: pr["url"])
      end

      if Agent::Github.ready?(pr)
        return Result.new(name: "ready_pr", status: "fixed", lease_outcome: "completed",
                          reason: "Ready PR #{pr['url']}", url: pr["url"])
      end

      if plans_committed
        return Result.new(name: "design_document", status: "needs_review", lease_outcome: "completed",
                          reason: "Design document committed under ~/code/claude/plans/")
      end

      # Only now, with no delivered artifact to protect, does the kill decide —
      # and it decides over the exit code, which a killed wrapper never wrote.
      # `failure` returns the issue to the queue: a killed attempt needs
      # RE-RUNNING, not a human's input.
      if killed
        # `cancelled` rather than `failed`, because that is the platform enum's
        # own word for this: "the executor killed the session on a 409 heartbeat,
        # or the hard timeout fired". Both close the lease as a failure for the
        # give-up count; only one of them says a machine did it on purpose.
        return failure(killed_reason(killed), attempt, url: pr && pr["url"], lease_outcome: "cancelled")
      end

      # AN OPERATION THAT RAN AND FAILED, above every remaining arm including a
      # clean exit code.
      #
      # This ordering is the load-bearing half of ISS-815, not the success arm
      # below it. A session sent to run `dev issues reconcile --apply` that
      # watched it exit 1 and then exited 0 itself is the most likely shape of
      # this failure — the wrapper's `echo $?` reports on CLAUDE, and Claude
      # finishing tidily says nothing about whether the thing it was sent to run
      # worked. Without this arm that run classified as `nothing_to_do` and, on a
      # producer-filed issue, DISMISSED itself.
      #
      # A failure, so the issue returns to the queue and the operation is run
      # again — safe because every operation reached this way is idempotent by
      # construction (both reconcilers evaluate everything outstanding on every
      # pass; `api publish` uploads the specs that are there).
      broken = Agent::Ops.failed(operations)
      if broken.any?
        return failure("Operation#{'s' if broken.length > 1} failed: #{Agent::Ops.describe(broken)}",
                       attempt, url: pr && pr["url"])
      end

      # THE API REFUSED THE SESSION (ISS-1129). Not a failure of the work, and
      # not an attempt: the CLI was answered 429 by the usage limit, printed
      # "You've hit your session limit", and exited 1 in under a second having
      # done nothing at all.
      #
      # Every arm below reads that exit code as a verdict on the WORK, and on
      # 2026-08-08 that is exactly what happened to ISS-986, ISS-992 and ISS-993:
      # three sessions refused in 90 seconds spent the whole `GIVE_UP_AFTER_FAILURES`
      # budget and parked all three in `needs_input`, which `dev issues claim`
      # never offers again. The issues were not hard; nothing ever looked at them.
      #
      # So it returns to `open` with the lease RELEASED rather than `failed` —
      # the platform's own word for a hand-back nobody failed at, which is
      # precisely this — and `attempt_number` therefore does not count it. A
      # refusal is free; it must cost the issue nothing.
      #
      # Below the delivered-artifact arms and below a failed operation, because a
      # session that did real work and was cut off at the limit still has to
      # report what it did. Above the draft/exit-code arms, which would otherwise
      # blame the session for stopping.
      if usage_limit
        return Result.new(name: "usage_limit", status: "open", lease_outcome: "released",
                          reason: usage_limit_reason(usage_limit))
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

      # THE OPS ARM: every operation this attempt ran reported success, and the
      # session then exited cleanly.
      #
      # `deployed`, not `fixed`. The two are not interchangeable here: `fixed`
      # means "resolved in a merged PR, awaiting release" and starts a deploy
      # watch that needs a fix url to derive an app from — an ops run has no PR
      # to give it, and a `fixed` with nothing to watch is how 49 issues came to
      # sit in `fixed` forever (ISS-737). `deployed` is the platform's own word
      # for "the fix is live, or needed no release", which is precisely an
      # operation whose effect already happened in production. It stamps
      # deployed_at, so the ordinary 7-day auto-verify applies unchanged, and it
      # is a RolledUpStatus, so a child filed this way stops holding its epic
      # open exactly like any other.
      #
      # Requires a CLEAN EXIT and no kill, and that is deliberate. Nothing here
      # knows how many operations the issue meant to run, so a session that ran
      # the first of three and then crashed must not read as done — the exit code
      # is what supplies "and there was nothing left to do". A retry re-runs the
      # operations that already succeeded, which is free: they are idempotent.
      if operations.any?
        return Result.new(name: "operation_completed", status: "deployed", lease_outcome: "completed",
                          reason: "Ran #{operations.length} operation#{'s' if operations.length > 1}: " \
                                  "#{Agent::Ops.describe(operations)}")
      end

      # Clean exit, nothing produced. Who filed the issue decides where it lands,
      # and this is the asymmetry that matters: an agent finding "nothing wrong"
      # with a bug a HUMAN filed is more often wrong than right, so it states
      # what it checked and a human decides. Agents never self-dismiss
      # human-filed work. A producer re-files if the condition recurs, so
      # dismissing its own issue is safe.
      if producer_filed
        Result.new(name: "nothing_to_do", status: "dismissed", lease_outcome: "completed",
                   reason: "Producer-filed issue: session completed with nothing to do")
      else
        Result.new(name: "nothing_to_do", status: "needs_input", lease_outcome: "completed",
                   reason: "Session completed without opening a PR or writing a plan. " \
                           "A human-authored issue is never auto-dismissed — see the session log for what was checked.")
      end
    end

    # ---- writing a verdict down, and reading it back ----
    #
    # The reap records its Result on the job record BEFORE it starts reclaiming
    # what that Result was derived from, and applies the recorded one if it has
    # to run again (ISS-741, `Agent::Jobs.mark_reaped`). These two are that
    # round trip, through JSON, so string keys both ways.

    def to_h(result) = result.to_h.transform_keys(&:to_s)

    # nil for anything that is not a Result this module wrote — a job record
    # from an executor that predates ISS-741, a truncated write, a hand-edited
    # file. The caller re-classifies then, which is exactly the old behaviour and
    # so never worse than it. Unknown keys are dropped rather than raised on, for
    # the same reason: a record written by a NEWER executor must not be able to
    # crash the reap that finds it mid-upgrade.
    def from_h(hash)
      return nil unless hash.is_a?(Hash)
      return nil if hash["name"].to_s.empty? || hash["status"].to_s.empty?
      Result.new(**Result.members.to_h { |field| [field, hash[field.to_s]] })
    end

    # A retryable failure returns the issue to `open` (the sweeper applies the
    # snoozed_until backoff server-side); the give-up threshold converts it to a
    # question for a human rather than an issue that ages silently.
    #
    # "in a row" is not decoration in these reasons — the old wording ("Attempt 3
    # of 3") was the bug restated on the timeline, on an issue whose first two
    # leases had failed at nothing.
    def failure(reason, attempt, url: nil, lease_outcome: "failed")
      if attempt >= GIVE_UP_AFTER_FAILURES
        Result.new(name: "gave_up", status: "needs_input", lease_outcome: lease_outcome, url: url,
                   reason: "#{reason}. Failure #{attempt} of #{GIVE_UP_AFTER_FAILURES} in a row — " \
                           "giving up and asking for input.")
      else
        Result.new(name: "failed", status: "open", lease_outcome: lease_outcome, url: url,
                   reason: "#{reason}. Failure #{attempt} of #{GIVE_UP_AFTER_FAILURES} in a row — " \
                           "returning to the queue.")
      end
    end

    # Written for the person reading the issue timeline weeks later, whose first
    # question is "what was wrong with this issue" — and the answer is nothing.
    # It says so in the first clause, before any detail, because that is the
    # whole point of separating this from a failure.
    def usage_limit_reason(usage_limit)
      message = usage_limit.is_a?(Hash) ? usage_limit["message"].to_s : usage_limit.to_s
      resets = usage_limit.is_a?(Hash) ? usage_limit["resets_at"] : nil
      [
        "NOT a failure of this issue: no session ever ran. The Claude API refused to start one " \
        "(HTTP #{Agent::Stream::USAGE_LIMIT_STATUS}, usage limit) and the CLI exited immediately",
        message.empty? ? nil : " — #{message}",
        resets.respond_to?(:utc) ? ". The limit resets at #{resets.utc.strftime('%Y-%m-%d %H:%M UTC')}" : nil,
        ". Returned to the queue; this attempt is not counted against the give-up limit.",
      ].compact.join
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
      %w[merged_pr ready_pr design_document operation_completed nothing_to_do].include?(result.name)
    end
  end
end
