#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
load File.expand_path('../bin/dev', __dir__)

# Covers the argument-validation DX for `dev invariants snooze` / `unsnooze`:
# all missing/bad args are reported at once (not one-at-a-time), the invariant
# name is a positional (a `--name X` guess is named as an unknown flag), and the
# command's usage line is shown inline so you don't have to hunt through help.
class TestDevInvariantsSnooze < Minitest::Test
  def capture_stderr_and_exit
    buf = StringIO.new
    old = $stderr
    $stderr = buf
    status = nil
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [buf.string, status]
  ensure
    $stderr = old
  end

  # ---- collect_invariant_name ----

  def test_single_positional_name_has_no_problems
    name, problems = collect_invariant_name(["my_invariant"])
    assert_equal "my_invariant", name
    assert_empty problems
  end

  def test_dash_dash_name_guess_is_reported_as_unknown_flag
    _name, problems = collect_invariant_name(["--name", "my_invariant"])
    assert_equal 1, problems.length
    assert_match(/unknown flag --name/, problems.first)
    assert_match(/positional argument, not --name/, problems.first)
  end

  def test_missing_name_is_reported
    name, problems = collect_invariant_name([])
    assert_nil name
    assert_includes problems, "missing invariant name (positional argument)"
  end

  def test_extra_positionals_are_reported
    _name, problems = collect_invariant_name(%w[a b])
    assert(problems.any? { |p| p.include?("expected a single invariant name but got 2") })
  end

  # ---- report_arg_problems ----

  def test_report_single_problem_is_one_line
    out, status = capture_stderr_and_exit do
      report_arg_problems("snooze", ["--app is required"], SNOOZE_USAGE)
    end
    assert_equal 1, status
    assert_match(/snooze: --app is required/, out)
    assert_match(/Usage: dev invariants snooze <name>/, out)
  end

  def test_report_multiple_problems_are_bulleted
    out, status = capture_stderr_and_exit do
      report_arg_problems("snooze", ["--app is required", "--days is required"], SNOOZE_USAGE)
    end
    assert_equal 1, status
    assert_match(/snooze: 2 problems:/, out)
    assert_match(/^  - --app is required$/, out)
    assert_match(/^  - --days is required$/, out)
  end

  def test_report_empty_problems_is_noop
    out, status = capture_stderr_and_exit { report_arg_problems("snooze", [], SNOOZE_USAGE) }
    assert_nil status
    assert_empty out
  end

  # ---- cmd_invariants_snooze (validation only; exits before any network) ----

  def test_snooze_no_args_reports_every_missing_arg_at_once
    out, status = capture_stderr_and_exit { cmd_invariants_snooze([]) }
    assert_equal 1, status
    assert_match(/missing invariant name/, out)
    assert_match(/--app is required/, out)
    assert_match(/--days is required/, out)
    assert_match(/--reason is required/, out)
    assert_match(%r{Usage: dev invariants snooze <name> --app APP --days N}, out)
  end

  def test_snooze_with_name_flag_guess_names_the_mistake
    # `--name x` recovers x as the positional name but still flags the stray
    # --name flag — so the only problem is the unknown flag, named clearly.
    args = ["--name", "x", "--app", "platform", "--days", "10", "--reason", "test"]
    out, status = capture_stderr_and_exit { cmd_invariants_snooze(args) }
    assert_equal 1, status
    assert_match(/snooze: unknown flag --name/, out)
    assert_match(/positional argument, not --name/, out)
  end

  def test_snooze_non_integer_days_is_reported
    args = ["my_invariant", "--app", "platform", "--days", "abc", "--reason", "test"]
    out, status = capture_stderr_and_exit { cmd_invariants_snooze(args) }
    assert_equal 1, status
    assert_match(/--days must be an integer >= 1/, out)
  end

  def test_snooze_zero_days_is_reported
    args = ["my_invariant", "--app", "platform", "--days", "0", "--reason", "test"]
    out, status = capture_stderr_and_exit { cmd_invariants_snooze(args) }
    assert_equal 1, status
    assert_match(/--days must be an integer >= 1/, out)
  end

  # ---- cmd_invariants_unsnooze ----

  def test_unsnooze_no_args_reports_name_and_app_together
    out, status = capture_stderr_and_exit { cmd_invariants_unsnooze([]) }
    assert_equal 1, status
    assert_match(/unsnooze: 2 problems:/, out)
    assert_match(/missing invariant name/, out)
    assert_match(/--app is required/, out)
    assert_match(%r{Usage: dev invariants unsnooze <name> --app APP}, out)
  end
end
