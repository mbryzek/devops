#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the two commands that WRITE what actually happened into the autonomy
# ledger — `dev autonomy outcome` and `dev autonomy reverted` — plus the one
# neighbouring read that dropped arguments the same way.
#
# The ledger's design point is that nothing in it silently misrepresents what
# happened, and an outcome is the only record of a decision after the fact:
# there is no second signal to reconcile it against later. So both ways of
# getting it wrong on the command line had to become usage errors rather than
# quiet reinterpretations (ISS-744):
#
#   dev autonomy outcome 4821 4822 --applied        # recorded 4821, dropped 4822
#   dev autonomy outcome 4821 --applied --failed x  # recorded applied: false
#
# Every other multi-positional subcommand in bin/dev already rejects the first
# shape; these did not, and the second had no check anywhere.
class TestDevAutonomyOutcome < Minitest::Test
  include DevTestSupport

  def decision(status: "applied")
    { "id" => "4821", "status" => status, "action" => "merge_pr",
      "subject" => { "type" => "pull_request", "id" => "374", "label" => "devops#374" } }
  end

  # Runs the command with the outcome POST stubbed, returning the body it SENT —
  # what was recorded is the thing under test, not what came back.
  def outcome_body(args, id: "4821")
    sent = nil
    with_stubbed_api("POST /autonomy/decisions/#{id}/outcome" => ->(body) { sent = body; decision }) do
      capture_stdout { cmd_autonomy_outcome(args) }
    end
    sent
  end

  # ---- outcome: extra decision ids ----

  # The reported bug. An operator closing out two decisions from one command line
  # had one of them recorded and no indication that the other was not.
  def test_outcome_rejects_a_second_decision_id_instead_of_dropping_it
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(%w[4821 4822 --applied]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): 4822/, out)
    assert_match(/run this once per decision id/, out)
  end

  def test_outcome_names_every_dropped_id
    out, = capture_stderr_and_exit { cmd_autonomy_outcome(%w[4821 4822 4823 --applied]) }
    assert_match(/unexpected argument\(s\): 4822, 4823/, out)
  end

  def test_outcome_requires_a_decision_id
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(["--applied"]) }
    assert_equal 1, status
    assert_match(/A decision id is required/, out)
  end

  # An empty positional URL-encodes to nothing and would POST to
  # /autonomy/decisions//outcome — a 404 at best, the wrong row at worst.
  def test_outcome_rejects_an_empty_decision_id
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(["", "--applied"]) }
    assert_equal 1, status
    assert_match(/A decision id is required/, out)
  end

  # ---- outcome: --applied vs --failed ----

  # The second reported bug: both flags assigned the same variable, so the last
  # one won and a contradictory command line recorded a FAILURE.
  def test_outcome_rejects_applied_and_failed_together
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(["4821", "--applied", "--failed", "boom"]) }
    assert_equal 1, status
    assert_match(/--applied and --failed are mutually exclusive/, out)
  end

  # ...in either order. Reading the resolved value could only ever catch one.
  def test_outcome_rejects_failed_and_applied_together
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(["4821", "--failed", "boom", "--applied"]) }
    assert_equal 1, status
    assert_match(/--applied and --failed are mutually exclusive/, out)
  end

  def test_outcome_requires_one_of_applied_or_failed
    out, status = capture_stderr_and_exit { cmd_autonomy_outcome(["4821"]) }
    assert_equal 1, status
    assert_match(/Pass exactly one of --applied or --failed/, out)
    refute_match(/mutually exclusive/, out)
  end

  # Every problem at once, so a wrong command line is corrected in one pass
  # rather than one usage error per run.
  def test_outcome_reports_all_the_problems_together
    out, = capture_stderr_and_exit { cmd_autonomy_outcome(["4821", "4822", "--applied", "--failed", "boom"]) }
    assert_match(/unexpected argument\(s\): 4822/, out)
    assert_match(/mutually exclusive/, out)
    assert_match(/outcome: 2 problems:/, out)
  end

  # ---- outcome: what a well-formed command still records ----

  def test_applied_records_a_success
    assert_equal({ applied: true }, outcome_body(%w[4821 --applied]))
  end

  def test_failed_records_the_error
    assert_equal({ applied: false, error: "boom" }, outcome_body(["4821", "--failed", "boom"]))
  end

  def test_the_undo_command_rides_along
    body = outcome_body(["4821", "--applied", "--undo-command", "gh pr revert 374"])
    assert_equal({ kind: "command", command: "gh pr revert 374" }, body[:undo])
  end

  # A repeated flag is not a contradiction — it says the same thing twice.
  def test_a_repeated_applied_is_not_a_contradiction
    assert_equal({ applied: true }, outcome_body(%w[4821 --applied --applied]))
  end

  # The contract violation the command exists to shout about is unchanged: a
  # ledger that never approved this decision exits non-zero.
  def test_a_contradicted_outcome_still_fails_loudly
    err, status = capture_stderr_and_exit do
      with_stubbed_api("POST /autonomy/decisions/4821/outcome" => decision(status: "contradicted")) do
        capture_stdout { cmd_autonomy_outcome(%w[4821 --applied]) }
      end
    end
    assert_equal 1, status
    assert_match(/the ledger never approved this decision/, err)
  end

  # ---- reverted ----

  def test_reverted_rejects_a_second_decision_id
    out, status = capture_stderr_and_exit { cmd_autonomy_reverted(%w[4821 4822]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): 4822/, out)
    assert_match(/run this once per decision id/, out)
  end

  def test_reverted_requires_a_decision_id
    out, status = capture_stderr_and_exit { cmd_autonomy_reverted([]) }
    assert_equal 1, status
    assert_match(/A decision id is required/, out)
  end

  def test_reverted_rejects_an_empty_decision_id
    out, status = capture_stderr_and_exit { cmd_autonomy_reverted([""]) }
    assert_equal 1, status
    assert_match(/A decision id is required/, out)
  end

  def reverted_body(args, id: "4821")
    sent = nil
    with_stubbed_api("POST /autonomy/decisions/#{id}/revert/completion" =>
                       ->(body) { sent = body; { "id" => id, "status" => "reverted" } }) do
      capture_stdout { cmd_autonomy_reverted(args) }
    end
    sent
  end

  def test_reverted_defaults_to_succeeded
    assert_equal({ succeeded: true }, reverted_body(%w[4821]))
  end

  def test_reverted_records_a_failure_with_its_note
    assert_equal({ succeeded: false, note: "selector moved" },
                 reverted_body(["4821", "--failed", "--note", "selector moved"]))
  end

  # ---- workflows: the same drop, on a read ----

  # Not an audited write, but it showed the first key and said nothing about the
  # rest — and a mistyped flag became a workflow key to GET.
  def test_workflows_rejects_a_second_key
    out, status = capture_stderr_and_exit { cmd_autonomy_workflows(%w[pr_auto_merge issue_triage]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): issue_triage/, out)
  end
end
