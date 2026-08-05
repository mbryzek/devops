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
    assert_equal "succeeded", result.lease_outcome

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
    assert_equal "succeeded", result.lease_outcome
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

  def test_crash_is_retryable_until_the_attempt_limit
    assert_equal "open", classify(exit_code: 2).status
    assert_equal "failed", classify(exit_code: 2).name
    assert_equal "open", classify(exit_code: 2, attempt: 2).status

    gave_up = classify(exit_code: 2, attempt: Agent::Outcome::MAX_ATTEMPTS)
    assert_equal "gave_up", gave_up.name
    assert_equal "needs_input", gave_up.status
    assert_equal "failed", gave_up.lease_outcome
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
    gave_up = classify(killed: { "reason" => "lease_lost" }, attempt: Agent::Outcome::MAX_ATTEMPTS)
    assert_equal "gave_up", gave_up.name
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

  def test_best_pr_prefers_merged_then_open_then_closed
    assert_equal "MERGED", Agent::Github.best_pr([CLOSED_PR, MERGED_PR, READY_PR])["state"]
    assert_equal "OPEN", Agent::Github.best_pr([CLOSED_PR, READY_PR])["state"]
    assert_nil Agent::Github.best_pr([])
    newer = READY_PR.merge("number" => 10)
    assert_equal 10, Agent::Github.best_pr([READY_PR, newer])["number"]
  end

  def test_success_predicate_drives_workspace_cleanup
    assert Agent::Outcome.success?(classify(pr: READY_PR))
    assert Agent::Outcome.success?(classify(plans_committed: true))
    assert Agent::Outcome.success?(classify(producer_filed: true))
    refute Agent::Outcome.success?(classify(exit_code: 2))
  end

  # ---- slug / branch ----

  def test_slug_shape_and_length_bound
    assert_equal "i120_x4q", Agent::Workspace.slug(120, suffix: "x4q")
    # The ceiling exists because macOS caps a unix socket path at 104 bytes and
    # sbt builds <feature>/<repo>/project/.sbtboot/server/<hash>/sock under it.
    (1..99_999).step(7919) do |n|
      slug = Agent::Workspace.slug(n)
      assert_operator slug.length, :<=, Agent::Workspace::MAX_SLUG_LENGTH, "slug #{slug} too long"
      assert_match(/\Ai\d+_[a-z0-9]{3}\z/, slug)
    end
  end

  def test_slug_refuses_to_generate_an_oversized_name
    assert_raises(RuntimeError) { Agent::Workspace.slug("1234567890123456789") }
  end

  def test_two_attempts_on_one_issue_get_different_slugs
    slugs = 20.times.map { Agent::Workspace.slug(120) }
    assert_operator slugs.uniq.length, :>, 1, "a fixed suffix would collide two attempts"
  end

  # The GC pattern must match exactly what the executor creates, and nothing
  # else: ~/code/ai also holds Mike's own feature dirs and gc runs rm -rf.
  def test_gc_slug_pattern_matches_agent_dirs_only
    assert_match Agent::Gc::AGENT_SLUG, Agent::Workspace.slug(120, suffix: "x4q")
    ["cr-backfill-coord", "agent-dispatch", "i120", "i120_toolong", "xi120_abc"].each do |name|
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
