#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the single-workflow view of `dev autonomy workflows KEY` — the command a
# playbook tells an autonomous loop to read its OWN envelope from before it acts.
#
# The property under test is that the rendering is total: every field the ledger
# returns on the envelope reaches the output. A hand-picked printer fails silently
# here, because an omitted field and an unset one look exactly alike, and the loop
# reading it has no way to tell "gated at reversible" from "not gated at all"
# (ISS-662 — max_reversibility was never printed at all).
class TestDevAutonomyWorkflows < Minitest::Test
  include DevTestSupport

  def envelope(allowed_repos: [], max_diff_lines: nil, required_assertions: [], max_reversibility: nil)
    { "allowed_repos" => allowed_repos, "max_diff_lines" => max_diff_lines,
      "required_assertions" => required_assertions, "max_reversibility" => max_reversibility }
  end

  def workflow(env = envelope)
    { "key" => "pr_auto_merge", "mode" => "dry_run", "description" => "Merge PRs that are green",
      "envelope" => env,
      "budget" => { "max_decisions_per_day" => nil, "max_auto_approved_per_day" => nil } }
  end

  def stats(decisions_today: 0, auto_approved_today: 0, blocked_today: 0, pending: 0,
            oldest_pending_at: nil, cost_today: 0, last_run_at: nil)
    { "decisions_today" => decisions_today, "auto_approved_today" => auto_approved_today,
      "blocked_today" => blocked_today, "pending" => pending,
      "oldest_pending_at" => oldest_pending_at, "cost_today" => cost_today,
      "last_run_at" => last_run_at }
  end

  def show(env)
    show_workflow(workflow(env))
  end

  def show_stats(st)
    show_workflow(workflow.merge("stats" => st))
  end

  def show_workflow(w)
    capture_stdout do
      with_stubbed_api("GET /autonomy/workflows/pr_auto_merge" => w) do
        cmd_autonomy_workflows(["pr_auto_merge"])
      end
    end
  end

  # The bug: the gate this workflow actually turns on was the one field the view
  # never showed.
  def test_prints_the_reversibility_ceiling_it_is_gated_at
    out = show(envelope(max_reversibility: "costly"))
    assert_match(/^  max rev:    costly and below/, out)
  end

  # ...and says so as a ceiling. "costly" alone reads as "costly decisions only",
  # which would have the loop hold every trivial one.
  def test_spells_out_the_reversibility_ordering
    assert_includes show(envelope(max_reversibility: "reversible")),
                    "trivial < reversible < costly < irreversible"
  end

  # Absent is permissive, not restrictive — the distinction the omission erased.
  def test_says_when_reversibility_does_not_gate_at_all
    assert_match(/^  max rev:    does not gate$/, show(envelope))
  end

  # An empty allowed_repos is "every repo", which a playbook that treats the list
  # as its work list reads backwards as "no repos" (the ISS-659 run enumerated
  # every mbryzek repo off this line).
  def test_an_empty_repo_list_says_it_is_not_a_work_list
    out = show(envelope)
    assert_match(/^  repos:      unrestricted — the envelope names no repos, so it is not a work list$/, out)
  end

  def test_renders_the_constrained_envelope
    out = show(envelope(allowed_repos: %w[devops platform], max_diff_lines: 400,
                        required_assertions: %w[ci_green no_schema_migration],
                        max_reversibility: "trivial"))
    assert_match(/^  repos:      devops, platform$/, out)
    assert_match(/^  max diff:   400$/, out)
    assert_match(/^  asserts:    ci_green, no_schema_migration$/, out)
    assert_match(/^  max rev:    trivial and below/, out)
  end

  # The regression guard for the whole class of bug: a field added to
  # autonomy_envelope that nobody taught this printer about still reaches the
  # output. Ugly beats invisible — invisible is what shipped for ISS-662.
  def test_a_field_the_printer_does_not_know_is_still_printed
    out = show(envelope.merge("max_repos_per_run" => 3, "allowed_hours" => []))
    assert_match(/^  max_repos_per_run: 3$/, out)
    assert_match(/^  allowed_hours: not set$/, out)
  end

  # Unchanged neighbours: the header and the budget line still frame the envelope.
  def test_still_prints_the_mode_and_the_budget
    out = show(envelope)
    assert_match(/^pr_auto_merge \(dry_run\)$/, out)
    assert_match(/^  budget:     - decisions\/day, - auto-approved\/day$/, out)
  end

  # A malformed or partial envelope must not take the command down: a loop that
  # cannot read its gate has to see the gate missing, not a stack trace.
  def test_a_missing_envelope_renders_every_field_as_unset
    out = capture_stdout do
      with_stubbed_api("GET /autonomy/workflows/pr_auto_merge" => workflow(nil)) do
        cmd_autonomy_workflows(["pr_auto_merge"])
      end
    end
    assert_match(/^  max rev:    does not gate$/, out)
    assert_match(/^  asserts:    none$/, out)
  end

  # What the workflow is allowed to do was here; what it has been doing was on the
  # list view only, so reading one workflow told you nothing about its behaviour.
  def test_prints_todays_counts_alongside_the_envelope
    out = show_stats(stats(decisions_today: 12, auto_approved_today: 9, pending: 2,
                           oldest_pending_at: "2026-08-02T11:00:00Z", cost_today: "0.42",
                           last_run_at: "2026-08-06T06:45:00Z"))
    assert_match(/^  today:      12 decision\(s\)$/, out)
    assert_match(/^  approved:   9 today$/, out)
    assert_match(/^  blocked:    0 today$/, out)
    assert_match(/^  pending:    2 awaiting a human \(all time\)$/, out)
    assert_match(/^  oldest:     2026-08-02T11:00:00Z$/, out)
    assert_match(/^  cost:       \$0.42 today$/, out)
    assert_match(/^  last run:   2026-08-06T06:45:00Z$/, out)
  end

  # ISS-756: with the daily budget gone, blocked is the remaining signal that a
  # released loop and its envelope have stopped agreeing. A bare count is a number
  # you have to already care about, so the view says what it means and how to read
  # the decisions behind it.
  def test_blocked_decisions_are_called_out_with_the_command_that_reads_them
    out = show_stats(stats(decisions_today: 5, blocked_today: 3))
    assert_match(/^  blocked:    3 today$/, out)
    assert_match(/3 decision\(s\) BLOCKED today/, out)
    assert_includes out,
                    "dev autonomy decisions --workflow pr_auto_merge --disposition blocked"
  end

  # ...and says which blocked decisions are NOT news. Every one pr_auto_merge had
  # on the day this shipped was a classification above its reversibility ceiling,
  # which is the ceiling working; calling those an alarm makes the call-out noise
  # on its first run.
  def test_the_call_out_separates_the_designed_hold_from_the_anomaly
    out = show_stats(stats(blocked_today: 8))
    assert_match(/above max_reversibility lands here BY DESIGN/, out)
    assert_match(/other reason means the envelope and the work no longer agree/, out)
  end

  # The quiet case is the common one, and a warning printed every day is a warning
  # nobody reads.
  def test_nothing_blocked_prints_no_warning
    out = show_stats(stats(decisions_today: 5))
    assert_match(/^  blocked:    0 today$/, out)
    refute_match(/BLOCKED/, out)
  end

  # Same totality guard as the envelope: a stats field nobody taught this printer
  # about still reaches the output, and an absent stats block does not crash the
  # one command a loop reads its own state from.
  def test_an_unknown_stats_field_is_still_printed
    out = show_stats(stats.merge("reverted_today" => 4))
    assert_match(/^  reverted_today: 4$/, out)
  end

  def test_a_missing_stats_block_renders_every_count_as_unset
    out = show(envelope)
    assert_match(/^  today:      -$/, out)
    assert_match(/^  blocked:    -$/, out)
    assert_match(/^  oldest:     nothing pending$/, out)
    assert_match(/^  last run:   never$/, out)
    refute_match(/BLOCKED/, out)
  end

  # The list view is a different shape and is not what a loop reads its gate from.
  def test_the_list_view_is_one_line_per_workflow
    out = capture_stdout do
      rows = [workflow.merge("stats" => { "decisions_today" => 66, "blocked_today" => 0, "pending" => 2 })]
      with_stubbed_api("GET /autonomy/workflows?limit=100" => rows) { cmd_autonomy_workflows([]) }
    end
    assert_match(/^pr_auto_merge\s+dry_run\s+decisions today 66\s+blocked 0\s+pending 2$/, out)
  end
end
