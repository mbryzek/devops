#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The dispatcher's pure decision functions: outcome classification, slug/branch
# generation, the producer registry's validation and in-flight predicate, and the
# retention rules. Each of these decides something irreversible-ish (a status
# transition, an rm -rf), and each is a plain function so it can be pinned here.
class TestDevAgentOutcome < Minitest::Test
  include DevTestSupport

  URL = "https://github.com/mbryzek/platform/pull/9".freeze
  READY_PR = { "url" => URL, "isDraft" => false, "state" => "OPEN", "number" => 9 }.freeze
  DRAFT_PR = { "url" => URL, "isDraft" => true, "state" => "OPEN", "number" => 9 }.freeze
  MERGED_PR = { "url" => URL, "isDraft" => false, "state" => "MERGED", "number" => 9 }.freeze
  CLOSED_PR = { "url" => URL, "isDraft" => false, "state" => "CLOSED", "number" => 9 }.freeze

  def classify(**overrides)
    Agent::Outcome.classify(**{ pr: nil, plans_committed: false, exit_code: 0, producer_filed: false,
                                attempt: 1, timed_out: false, killed: nil }.merge(overrides))
  end

  # ---- outcome classification ----

  # ISS-364 #1. A PR merged before the reap ran was invisible to a lookup that
  # asked only for OPEN PRs, so the strongest possible evidence of success --
  # the fix is on main -- was the one case that classified as failure, and a
  # producer-filed issue got DISMISSED with its fix merged.
  def test_merged_pr_is_fixed_and_outranks_every_other_signal
    result = classify(pr: MERGED_PR)
    assert_equal "merged_pr", result.name
    assert_equal "fixed", result.status
    assert_equal URL, result.url
    assert_equal "completed", result.lease_outcome

    assert_equal "merged_pr", classify(pr: MERGED_PR, exit_code: 2).name
    assert_equal "merged_pr", classify(pr: MERGED_PR, exit_code: nil, timed_out: true).name
    assert_equal "merged_pr", classify(pr: MERGED_PR, plans_committed: true).name
    assert_equal "merged_pr", classify(pr: MERGED_PR, killed: { "reason" => "lease_lost" }).name
    assert Agent::Outcome.success?(classify(pr: MERGED_PR)), "a merged PR must release the workspace"
  end

  # A closed-unmerged PR is a rejected attempt, not a delivery. It must not read
  # as success, and it must not read as a draft left open either.
  def test_closed_unmerged_pr_is_not_a_result
    result = classify(pr: CLOSED_PR, producer_filed: true)
    assert_equal "nothing_to_do", result.name
    refute_match(/never marked ready/, result.reason)
  end

  def test_ready_pr_is_fixed_and_carries_the_url
    result = classify(pr: READY_PR)
    assert_equal "ready_pr", result.name
    assert_equal "fixed", result.status
    assert_equal READY_PR["url"], result.url
    assert_equal "completed", result.lease_outcome
  end

  # A ready PR wins even over a non-zero exit: the artifact is the outcome, and
  # `claude --print` exiting non-zero after pushing a reviewable PR must not throw
  # the work away.
  def test_ready_pr_wins_over_a_nonzero_exit
    assert_equal "fixed", classify(pr: READY_PR, exit_code: 1).status
  end

  def test_draft_pr_is_not_a_result
    result = classify(pr: DRAFT_PR)
    assert_equal "failed", result.name
    assert_equal "open", result.status
    assert_match(/never marked ready/, result.reason)
  end

  def test_design_document_is_needs_review
    result = classify(plans_committed: true)
    assert_equal "design_document", result.name
    assert_equal "needs_review", result.status
  end

  # The asymmetry that keeps the fleet honest: agents never self-dismiss
  # human-filed work.
  def test_nothing_to_do_dismisses_only_producer_filed_issues
    assert_equal "dismissed", classify(producer_filed: true).status
    assert_equal "needs_input", classify(producer_filed: false).status
    assert_equal "nothing_to_do", classify(producer_filed: false).name
  end

  # ---- the ops arm (ISS-815) ----
  #
  # A session whose job is to RUN something — `dev features reconcile --apply`,
  # `api publish` — changes no code, so it produced neither of the artifacts the
  # arms above look for and fell all the way through to `nothing_to_do`. On a
  # producer-filed issue that means DISMISSED: a reconcile that moved twelve
  # issues and a reconcile that never ran classified identically.

  def ops(operation: "features-reconcile", status: 0, timed_out: false, summary: "2 processed, 1 purged.")
    Agent::Ops::Record.new(operation: operation, status: status, timed_out: timed_out, summary: summary,
                           argv: %w[dev features reconcile --apply], effects: {},
                           started_at: "2026-08-07T15:00:00Z", finished_at: "2026-08-07T15:00:12Z")
  end

  # `deployed`, not `fixed`. An ops run has no PR to give a deploy watch, and a
  # `fixed` with nothing to watch is how 49 issues came to sit in `fixed` forever
  # (ISS-737). `deployed` is the platform's own word for "live, or needed no
  # release", it stamps deployed_at so the 7-day auto-verify applies unchanged,
  # and it is a RolledUpStatus so a child filed this way releases its epic.
  def test_a_completed_operation_closes_the_issue_as_deployed
    result = classify(operations: [ops], producer_filed: true)
    assert_equal "operation_completed", result.name
    assert_equal "deployed", result.status
    assert_equal "completed", result.lease_outcome
    assert Agent::Outcome.success?(result), "a completed operation must release the workspace"
  end

  # The whole value of having run it. A contract that recorded only "the process
  # exited 0" would reproduce ISS-809's failure mode — silence indistinguishable
  # from success — one level up, so the counts have to reach the timeline.
  def test_the_arm_carries_what_the_operation_did_not_merely_that_it_ran
    reason = classify(operations: [ops, ops(operation: "issues-reconcile", summary: "3 deployed.")]).reason
    assert_match(/2 operations/, reason)
    assert_match(/features-reconcile — 2 processed, 1 purged./, reason)
    assert_match(/issues-reconcile — 3 deployed./, reason)
  end

  # THE DANGEROUS ONE. The wrapper's `echo $?` reports on CLAUDE, and Claude
  # exiting tidily says nothing about whether the thing it was sent to run
  # worked. Without this arm, a session that watched `dev issues reconcile
  # --apply` exit 1 and then finished cleanly classified as `nothing_to_do` and,
  # on a producer-filed issue, dismissed itself.
  def test_an_operation_that_failed_beats_the_sessions_own_clean_exit
    result = classify(operations: [ops(status: 1)], exit_code: 0, producer_filed: true)
    assert_equal "failed", result.name
    assert_equal "open", result.status
    assert_match(/Operation failed: features-reconcile — exited 1/, result.reason)
  end

  def test_one_failed_operation_condemns_the_run_even_beside_a_successful_one
    result = classify(operations: [ops, ops(operation: "issues-reconcile", status: 2)], exit_code: 0)
    assert_equal "failed", result.name
    assert_match(/issues-reconcile — exited 2/, result.reason)
    refute_match(/features-reconcile/, result.reason, "only the failures are the diagnosis")
  end

  def test_a_timed_out_operation_is_a_failure_not_a_result
    result = classify(operations: [ops(status: nil, timed_out: true)], exit_code: 0)
    assert_equal "failed", result.name
    assert_match(/timed out/, result.reason)
  end

  # The ops arm requires a CLEAN EXIT, and this is why: nothing here knows how
  # many operations the issue meant to run, so a session that ran the first of
  # three and then died must not read as done. The exit code is what supplies
  # "and there was nothing left to do"; retrying is free because every operation
  # reached this way is idempotent.
  def test_a_successful_operation_does_not_rescue_a_session_that_crashed_after_it
    assert_equal "failed", classify(operations: [ops], exit_code: 1).name
    assert_equal "failed", classify(operations: [ops], exit_code: nil).name
    assert_match(/KILLED/, classify(operations: [ops], killed: { "reason" => "timeout" }).reason)
    assert_match(/never marked ready/, classify(operations: [ops], pr: DRAFT_PR).reason)
  end

  # Delivered code still outranks a chore. A session that found the reconciler
  # broken, fixed it, and left a ready PR delivered the more valuable artifact;
  # the chore is re-filed by the next release either way. Stated as a test
  # because the order is a judgement call, not an accident.
  def test_delivered_code_still_outranks_a_completed_operation
    assert_equal "merged_pr", classify(operations: [ops], pr: MERGED_PR).name
    assert_equal "ready_pr", classify(operations: [ops], pr: READY_PR).name
    assert_equal "design_document", classify(operations: [ops], plans_committed: true).name
  end

  # No operations is exactly the old behaviour: this arm may only ever ADD a
  # positive outcome, never reinterpret a run that recorded nothing.
  def test_a_run_with_no_operations_classifies_exactly_as_before
    assert_equal "dismissed", classify(operations: [], producer_filed: true).status
    assert_equal "needs_input", classify(operations: [], producer_filed: false).status
  end

  def test_crash_is_retryable_until_three_failures_in_a_row
    assert_equal "open", classify(exit_code: 2).status
    assert_equal "failed", classify(exit_code: 2).name
    assert_equal "open", classify(exit_code: 2, attempt: 2).status

    gave_up = classify(exit_code: 2, attempt: Agent::Outcome::GIVE_UP_AFTER_FAILURES)
    assert_equal "gave_up", gave_up.name
    assert_equal "needs_input", gave_up.status
    assert_equal "failed", gave_up.lease_outcome
    assert_match(/Failure 3 of 3 in a row/, gave_up.reason)
    assert_match(/Failure 1 of 3 in a row/, classify(exit_code: 2).reason)
  end

  # ---- a session the API refused to start (ISS-1129) ----
  #
  # ISS-986, ISS-992 and ISS-993 were driven to `needs_input` on 2026-08-08
  # without a session ever running: the Claude API answered 429 ("You've hit your
  # session limit"), the CLI exited 1 in under a second, and three of those in
  # ninety seconds spent the whole give-up budget. `needs_input` is the status
  # `dev issues claim` never offers, so all three stopped being work anyone would
  # ever pick up — over a quota, not over anything about the issues.

  REFUSED = { "message" => "You've hit your session limit · resets 1am (America/New_York)",
              "resets_at" => Time.utc(2026, 8, 8, 5, 0, 0) }.freeze

  def test_a_refused_session_returns_to_the_queue_and_is_not_an_attempt
    result = classify(exit_code: 1, usage_limit: REFUSED)
    assert_equal "usage_limit", result.name
    assert_equal "open", result.status
    # `released` — the platform's word for a hand-back nobody failed at — is what
    # keeps `attempt_number` from counting this, and is the whole fix.
    assert_equal "released", result.lease_outcome
  end

  # THE THING THAT WENT WRONG, pinned: three refusals in a row must not give up.
  def test_refusals_never_accumulate_toward_giving_up
    history = [lease(1, "released"), lease(2, "released"), lease("now", nil)]
    assert_equal 1, attempt_number(history), "a released lease is not a failed attempt"
    3.times do |i|
      result = classify(exit_code: 1, usage_limit: REFUSED, attempt: i + 1)
      assert_equal "open", result.status
      refute_equal "gave_up", result.name
    end
  end

  # The timeline is where a human answers "what was wrong with this issue", and
  # for this outcome the answer is nothing. It has to say so, and say when the
  # limit lifts, without anybody opening a log on the runner.
  def test_the_reason_says_no_session_ran_and_when_the_limit_resets
    reason = classify(exit_code: 1, usage_limit: REFUSED).reason
    assert_match(/NOT a failure of this issue: no session ever ran/, reason)
    assert_match(/429/, reason)
    assert_match(/hit your session limit/, reason)
    assert_match(/resets at 2026-08-08 05:00 UTC/, reason)
    assert_match(/not counted against the give-up limit/, reason)
    refute_match(/Failure \d of \d/, reason)
  end

  def test_a_refusal_with_no_reset_instant_still_reads_clearly
    reason = classify(exit_code: 1, usage_limit: { "message" => "", "resets_at" => nil }).reason
    assert_match(/no session ever ran/, reason)
    refute_match(/resets at/, reason)
  end

  # Below every delivered artifact. A session that did its work and was refused
  # on a LATER turn still has to report what it delivered — the refusal is only
  # the whole story when there is nothing else.
  def test_delivered_work_outranks_a_refusal
    assert_equal "merged_pr", classify(pr: MERGED_PR, usage_limit: REFUSED).name
    assert_equal "ready_pr", classify(pr: READY_PR, usage_limit: REFUSED).name
    assert_equal "design_document", classify(plans_committed: true, usage_limit: REFUSED).name
    # Signal 3 is knowledge only the executor has, and it stays on top: a session
    # the tick killed is reported as killed even if the log also holds a refusal.
    killed = classify(killed: { "reason" => "timeout" }, usage_limit: REFUSED)
    assert_match(/KILLED by the tick/, killed.reason)
    assert_equal "cancelled", killed.lease_outcome
  end

  # Above the arms that blame the SESSION for stopping: an exit code, a hard
  # timeout, and a draft PR are all "you were given a turn and did not finish
  # it", which is not what happened here.
  def test_a_refusal_outranks_every_verdict_on_the_session_itself
    assert_equal "usage_limit", classify(pr: DRAFT_PR, usage_limit: REFUSED).name
    assert_equal "usage_limit", classify(exit_code: nil, usage_limit: REFUSED).name
    assert_equal "usage_limit", classify(exit_code: 1, timed_out: true, usage_limit: REFUSED).name
    assert_equal "usage_limit", classify(exit_code: 0, producer_filed: true, usage_limit: REFUSED).name
  end

  # A refusal is not success: nothing ran, so the workspace is kept for the
  # retry that resumes this same slug rather than deleted as finished work.
  def test_a_refusal_is_not_treated_as_a_completed_run
    refute Agent::Outcome.success?(classify(exit_code: 1, usage_limit: REFUSED))
  end

  # ---- the give-up count: failures IN A ROW, not leases (ISS-734) ----
  #
  # Every lease this issue ever had was counted as an attempt, so an issue with
  # an ordinary lifetime — reopened for a regression, reclaimed, handed back —
  # gave up on its FIRST real failure and landed in `needs_input`, which
  # `dev issues claim` never offers again. No test exercised a mixed history,
  # which is exactly why the same defect went unnoticed in two repos.

  # One lease row as the platform returns it. `outcome` nil is a LIVE lease.
  def lease(id, outcome, at: "2026-08-06T00:00:0#{id}Z")
    { "id" => "lse-#{id}", "outcome" => outcome, "created" => { "at" => at } }
  end

  def attempt_number(history, lease_id: "lse-now")
    Agent::Outcome.attempt_number(history, lease_id: lease_id)
  end

  # THE reported failure. Two ordinary released leases and a live one: the next
  # failure is the issue's first, not its third.
  def test_leases_that_failed_at_nothing_do_not_spend_the_give_up_budget
    history = [lease(1, "released"), lease(2, "released"), lease("now", nil)]
    assert_equal 1, attempt_number(history)
    assert_equal "open", classify(pr: DRAFT_PR, attempt: attempt_number(history)).status
  end

  def test_three_failures_in_a_row_still_give_up
    history = [lease(1, "failed"), lease(2, "failed"), lease("now", nil)]
    assert_equal 3, attempt_number(history)
    assert_equal "gave_up", classify(exit_code: 1, attempt: attempt_number(history)).name
  end

  # The other half: an attempt that ENDED WELL starts the run over, so a issue
  # that failed twice a month ago and has since been fixed and reopened gets a
  # full budget again.
  def test_an_attempt_that_ended_well_starts_the_count_over
    history = [lease(1, "failed"), lease(2, "failed"), lease(3, "completed"), lease(4, "failed"),
               lease("now", nil)]
    assert_equal 2, attempt_number(history)
    assert_equal 1, attempt_number([lease(1, "failed"), lease(2, "released"), lease("now", nil)])
  end

  # `expired` (nobody was there — the platform's sweeper wrote it) and
  # `cancelled` (the tick killed the session) are failures too: all three mean
  # the attempt delivered nothing and the next one is a retry.
  def test_expired_and_cancelled_leases_count_as_failures
    history = [lease(1, "expired"), lease(2, "cancelled"), lease("now", nil)]
    assert_equal 3, attempt_number(history)
  end

  # This attempt's own lease is the +1. When the sweeper closed it as `expired`
  # out from under the session the reap is classifying right now, it must be
  # counted once — not once as history and once as this attempt.
  def test_this_attempts_own_lease_is_never_counted_twice
    history = [lease(1, "failed"), lease("now", "expired")]
    assert_equal 2, attempt_number(history)
  end

  # A lease that has not ended yet says nothing either way: it is not a failure,
  # and it is not the clean answer that would reset the run.
  def test_a_live_lease_neither_counts_nor_resets
    assert_equal 2, attempt_number([lease(1, "failed"), lease(2, nil), lease("now", nil)])
    assert_equal 1, attempt_number([])
  end

  # The lease is where the count is read from, so the executor has to write it —
  # in the platform's own vocabulary. `succeeded` was never one of
  # `issue_lease_outcome`'s values (completed/failed/expired/released/cancelled).
  def test_every_result_closes_its_lease_with_a_platform_outcome
    valid = %w[completed failed expired released cancelled]
    [classify(pr: MERGED_PR), classify(pr: READY_PR), classify(plans_committed: true),
     classify(producer_filed: true), classify(producer_filed: false), classify(pr: DRAFT_PR),
     classify(exit_code: 1), classify(killed: { "reason" => "timeout" }),
     classify(exit_code: 1, usage_limit: REFUSED),
     classify(exit_code: 1, attempt: 3)].each do |result|
      assert_includes valid, result.lease_outcome, "#{result.name} closes its lease with an unknown outcome"
    end
  end

  # The enum's own word for a session the executor stopped: "the executor killed
  # the session on a 409 heartbeat, or the hard timeout fired".
  def test_a_killed_session_closes_its_lease_as_cancelled
    assert_equal "cancelled", classify(killed: { "reason" => "lease_lost" }).lease_outcome
    assert_equal "cancelled", classify(killed: { "reason" => "timeout" }, attempt: 3).lease_outcome
    assert_equal "failed", classify(exit_code: 1).lease_outcome
  end

  # A killed session never writes an exit code. Treated as a failure, never as a
  # clean "nothing to do" — otherwise a timed-out producer issue would be
  # silently dismissed.
  def test_missing_exit_code_is_a_failure_not_a_clean_exit
    result = classify(exit_code: nil, timed_out: true, producer_filed: true)
    assert_equal "failed", result.name
    assert_equal "open", result.status
  end

  # ISS-364, the part `timed_out` was hiding: `nil.to_i` is 0, so an absent
  # exit_code file on its own read as a CLEAN exit. The wrapper writes that file
  # as its last act, so its absence means the process died without finishing.
  def test_absent_exit_code_alone_is_a_failure_even_with_no_timeout
    result = classify(exit_code: nil, producer_filed: true)
    assert_equal "failed", result.name
    assert_equal "open", result.status
    assert_match(/no exit code/, result.reason)
  end

  # ISS-364 #2. The tick killed the session five seconds before the reap and then
  # reported that it "completed without opening a PR", parking a human-filed
  # issue at needs_input. Nothing needs a human — it needs re-running.
  def test_a_killed_session_is_reported_as_killed_and_returns_to_the_queue
    result = classify(killed: { "reason" => "lease_lost" }, exit_code: nil)
    assert_equal "failed", result.name
    assert_equal "open", result.status
    assert_match(/KILLED by the tick/, result.reason)
    assert_match(/lease/, result.reason)
    refute_match(/completed/, result.reason)
  end

  # The kill outranks the exit code and the draft-PR message, both of which
  # describe a session that chose to stop. It never outranks delivered work.
  def test_kill_beats_the_artifacts_the_kill_prevented
    assert_match(/KILLED/, classify(killed: { "reason" => "timeout" }, exit_code: 0).reason)
    assert_match(/KILLED/, classify(killed: { "reason" => "lease_lost" }, pr: DRAFT_PR).reason)
    assert_equal URL, classify(killed: { "reason" => "lease_lost" }, pr: DRAFT_PR).url
    assert_equal "design_document", classify(killed: { "reason" => "lease_lost" }, plans_committed: true).name
  end

  def test_an_unrecognized_kill_reason_still_reports_a_kill
    assert_match(/KILLED by the tick \(sigsegv\)/, classify(killed: { "reason" => "sigsegv" }).reason)
    assert_match(/reason not recorded/, classify(killed: {}).reason)
  end

  # A human-filed issue that was killed must never land on needs_input while
  # attempts remain: `needs_input` means "a human must decide something".
  def test_a_killed_human_filed_issue_is_not_parked_for_a_human
    assert_equal "open", classify(killed: { "reason" => "lease_lost" }, producer_filed: false).status
    gave_up = classify(killed: { "reason" => "lease_lost" }, attempt: Agent::Outcome::GIVE_UP_AFTER_FAILURES)
    assert_equal "gave_up", gave_up.name
  end

  # ---- writing a verdict down and reading it back (ISS-741) ----
  #
  # The reap records its Result on the job record before it deletes the
  # workspace that Result was derived from, and applies the recorded one if the
  # outcome write fails and the job has to be reaped again. That round trip goes
  # through JSON, so it is only as good as these two functions.

  def test_a_recorded_result_round_trips_through_json
    # One of each shape, including the two that leave `url` nil.
    [classify(pr: READY_PR), classify(plans_committed: true), classify(exit_code: 1),
     classify(producer_filed: true)].each do |result|
      restored = Agent::Outcome.from_h(JSON.parse(JSON.generate(Agent::Outcome.to_h(result))))
      assert_equal result, restored, "#{result.name} did not survive the job record"
    end
  end

  # A job record written before ISS-741 has no verdict on it, and a truncated or
  # hand-edited one has half of one. Both must read back as "nothing recorded",
  # which sends the reap back to classifying — the old behaviour, and never worse
  # than it. What must not happen is the reap raising on a file it did not write.
  def test_an_unrecognizable_verdict_reads_back_as_nothing_recorded
    [nil, "not a hash", {}, { "url" => URL }, { "name" => "ready_pr" }, { "status" => "fixed" }].each do |junk|
      assert_nil Agent::Outcome.from_h(junk), "#{junk.inspect} was accepted as a recorded verdict"
    end
  end

  # A verdict written by a NEWER executor, carrying a field this one has never
  # heard of. Dropped, not raised on: the two sides of a fleet mid-`git pull` are
  # 30 seconds apart, and a reap that dies on an unknown key strands the lease.
  def test_an_unknown_field_on_a_recorded_verdict_is_dropped
    forward = Agent::Outcome.to_h(classify(pr: READY_PR)).merge("invented_later" => true)
    assert_equal classify(pr: READY_PR), Agent::Outcome.from_h(forward)
  end

  # ---- PR state predicates and ranking (ISS-364 / ISS-365) ----

  def test_pr_state_predicates_are_case_insensitive
    # `gh pr list` returns MERGED; `gh search prs` returns merged.
    assert Agent::Github.merged?("state" => "merged")
    assert Agent::Github.merged?("state" => "MERGED")
    refute Agent::Github.merged?(nil)
    assert Agent::Github.ready?(READY_PR)
    refute Agent::Github.ready?(DRAFT_PR)
    refute Agent::Github.ready?(MERGED_PR), "a merged PR is not an open ready PR"
    assert Agent::Github.draft?(DRAFT_PR)
    refute Agent::Github.draft?(CLOSED_PR)
  end

  def test_primary_pr_prefers_merged_then_open_then_closed
    assert_equal "MERGED", Agent::Github.primary_pr([CLOSED_PR, MERGED_PR, READY_PR])["state"]
    assert_equal "OPEN", Agent::Github.primary_pr([CLOSED_PR, READY_PR])["state"]
    assert_nil Agent::Github.primary_pr([])
    newer = READY_PR.merge("number" => 10)
    assert_equal 10, Agent::Github.primary_pr([READY_PR, newer])["number"]
  end

  def test_success_predicate_drives_workspace_cleanup
    assert Agent::Outcome.success?(classify(pr: READY_PR))
    assert Agent::Outcome.success?(classify(plans_committed: true))
    assert Agent::Outcome.success?(classify(producer_filed: true))
    refute Agent::Outcome.success?(classify(exit_code: 2))
  end

  # ---- slug / branch ----

  def test_slug_shape_and_length_bound
    assert_equal "i120", Agent::Workspace.slug(120)
    assert_equal "i682_c07", Agent::Workspace.slug(700, parent_number: 682, child_index: 7)
    assert_equal "i682_c17", Agent::Workspace.slug(700, parent_number: 682, child_index: 17)
    # The ceiling exists because macOS caps a unix socket path at 104 bytes and
    # sbt builds <feature>/<repo>/project/.sbtboot/server/<hash>/sock under it.
    (1..99_999).step(7919) do |n|
      standalone = Agent::Workspace.slug(n)
      child = Agent::Workspace.slug(n, parent_number: n, child_index: 99)
      [standalone, child].each do |slug|
        assert_operator slug.length, :<=, Agent::Workspace::MAX_SLUG_LENGTH, "slug #{slug} too long"
        assert Agent::Workspace.valid_slug?(slug), "#{slug} must be a slug this executor admits"
      end
    end
  end

  # Zero-padded, and it is load-bearing rather than tidy: GitHub's `head:` search
  # qualifier is a PREFIX match on the whole branch name, so an unpadded
  # `i682_c1` would match `i682_c10` and the reap of child 1 could adopt child
  # 10's pull request.
  def test_a_child_branch_is_never_a_prefix_of_a_sibling_branch
    names = (1..99).map { |i| Agent::Workspace.slug(700 + i, parent_number: 682, child_index: i) }
    names.each do |name|
      others = names - [name]
      refute others.any? { |o| o.start_with?(name) }, "#{name} is a prefix of a sibling branch"
    end
  end

  def test_slug_refuses_to_generate_an_oversized_name
    assert_raises(RuntimeError) { Agent::Workspace.slug("1234567890123456789") }
  end

  # The point of ISS-767, and the exact inverse of what this asserted before: a
  # second attempt has to arrive at the branch the first one pushed, or review
  # feedback opens a second PR instead of updating the one under review.
  def test_two_attempts_on_one_issue_get_the_same_slug
    assert_equal 1, 20.times.map { Agent::Workspace.slug(120) }.uniq.length
    assert_equal 1, 20.times.map { Agent::Workspace.slug(700, parent_number: 682, child_index: 7) }.uniq.length
  end

  # The index is a position in a STABLE ordering: by issue number, over every
  # child the epic has, so a runner computes the same answer as the runner that
  # made the last attempt.
  def test_child_index_is_the_position_by_issue_number
    numbers = %w[710 682 699]
    assert_equal 1, Agent::Workspace.child_index(numbers, "682")
    assert_equal 2, Agent::Workspace.child_index(numbers, "699")
    assert_equal 3, Agent::Workspace.child_index(numbers, "710")
    assert_nil Agent::Workspace.child_index(numbers, "800"), "an issue outside the list has no position"
    assert_nil Agent::Workspace.child_index(numbers, nil)
    assert_nil Agent::Workspace.child_index(nil, "682")
    assert_equal 2, Agent::Workspace.child_index(%w[710 x 682 699 682], "699"),
                 "junk and duplicates must not shift a position"
  end

  # The tracker stores issue numbers ZERO-PADDED, and `Integer("0767")` is 503 in
  # Ruby: a leading zero means octal. Read that way the children reorder and a
  # retry computes a different branch than the attempt it is resuming.
  def test_a_zero_padded_number_is_read_as_decimal_not_octal
    assert_equal 3, Agent::Workspace.child_index(%w[0000682 0000699 0000710], "0000710")
    assert_equal 3, Agent::Workspace.child_index(%w[682 699 710], "0000710")
  end

  # An issue number is monotonic, so a child filed LATER lands at the end and
  # cannot renumber the children that already have branches.
  def test_a_later_child_does_not_renumber_its_predecessors
    before = %w[682 699 710]
    after = before + %w[755]
    before.each do |n|
      assert_equal Agent::Workspace.child_index(before, n), Agent::Workspace.child_index(after, n)
    end
    assert_equal 4, Agent::Workspace.child_index(after, "755")
  end

  # The GC pattern must match exactly what the executor creates, and nothing
  # else: ~/code/ai also holds Mike's own feature dirs and gc runs rm -rf.
  #
  # `i120` IS an executor slug now (the standalone form), and the legacy
  # `i120_x4q` still has to be one for as long as a workspace minted before
  # ISS-767 is on any disk — dropping it would leave those invisible to
  # `Agent::Gc` and fair game for `dev aidirs prune`, which skips precisely what
  # this matches.
  def test_gc_slug_pattern_matches_agent_dirs_only
    ["i120", "i120_x4q", "i682_c07", "i682_c100"].each do |name|
      assert_match Agent::Gc::AGENT_SLUG, name, "#{name} is a workspace the executor owns"
    end
    ["cr-backfill-coord", "agent-dispatch", "iss226-rev-src", "i120_toolong", "xi120_abc",
     "i120_c", "i120_cx", "i682_c07_sig", "i", "120"].each do |name|
      refute_match Agent::Gc::AGENT_SLUG, name, "#{name} must not look like an agent workspace"
    end
  end

  # ---- retention ----

  def test_retention_windows_favour_failures
    assert_equal Agent::Gc::TERMINAL_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "ready_pr" })
    assert_equal Agent::Gc::TERMINAL_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "nothing_to_do" })
    assert_equal Agent::Gc::FAILED_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "failed" })
    assert_equal Agent::Gc::FAILED_ISSUE_DAYS, Agent::Gc.retention_days("outcome" => { "name" => "gave_up" })
    assert_operator Agent::Gc::FAILED_ISSUE_DAYS, :>, Agent::Gc::TERMINAL_ISSUE_DAYS
  end

  def test_gc_plan_applies_one_rule_per_kind
    Dir.mktmpdir do |root|
      logs = File.join(root, "logs")
      workspaces = File.join(root, "ai")
      with_env("DEV_AGENT_LOG_ROOT" => logs, "DEV_AGENT_WORKSPACE_ROOT" => workspaces) do
        now = Time.utc(2026, 8, 3, 12, 0, 0)
        write(File.join(logs, "tick", "2026-06-01.log"), "old")     # 63 days
        write(File.join(logs, "tick", "2026-08-01.log"), "recent")  # 2 days
        write_meta(logs, 100, "ready_pr", now - 20 * 86_400)        # terminal, keep 14 -> collect
        write_meta(logs, 101, "ready_pr", now - 5 * 86_400)         # terminal, keep 14 -> keep
        write_meta(logs, 102, "gave_up",  now - 20 * 86_400)        # failed,   keep 30 -> keep
        write_meta(logs, 103, nil, nil)                             # still running -> never collect
        stale = File.join(workspaces, "i120_abc")
        FileUtils.mkdir_p(stale)
        File.utime(now - 9 * 86_400, now - 9 * 86_400, stale)
        fresh = File.join(workspaces, "i121_abc")
        FileUtils.mkdir_p(fresh)
        mine = File.join(workspaces, "agent-dispatch")
        FileUtils.mkdir_p(mine)
        File.utime(now - 900 * 86_400, now - 900 * 86_400, mine)

        paths = Agent::Gc.plan(now: now).map(&:first)
        assert_includes paths, File.join(logs, "tick", "2026-06-01.log")
        refute_includes paths, File.join(logs, "tick", "2026-08-01.log")
        assert_includes paths, File.join(logs, "issues", "ISS-100")
        refute_includes paths, File.join(logs, "issues", "ISS-101")
        refute_includes paths, File.join(logs, "issues", "ISS-102")
        refute_includes paths, File.join(logs, "issues", "ISS-103")
        assert_includes paths, stale
        refute_includes paths, fresh
        refute_includes paths, mine, "gc must never touch a hand-made feature dir"
      end
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def write_meta(logs, number, outcome, finished_at)
    meta = { "issue" => number }
    meta["outcome"] = { "name" => outcome } if outcome
    meta["finished_at"] = finished_at.utc.iso8601 if finished_at
    write(File.join(logs, "issues", "ISS-#{number}", "meta.json"), JSON.generate(meta))
  end

  def with_env(pairs)
    original = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end
end
