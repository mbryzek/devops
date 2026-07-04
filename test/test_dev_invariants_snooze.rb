#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the argument-validation DX for `dev invariants snooze` / `unsnooze`:
# all missing/bad args are reported at once (not one-at-a-time), the invariant
# name is a positional (a `--name X` guess is named as an unknown flag), and the
# command's usage line is shown inline so you don't have to hunt through help.
class TestDevInvariantsSnooze < Minitest::Test
  include DevTestSupport

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
    assert_match(/positional argument — pass it without a flag/, problems.first)
  end

  def test_unknown_flag_message_names_the_actual_flag_not_name
    # The hint must reference whatever flag the user actually typed, never a
    # hardcoded --name they never used.
    _name, problems = collect_invariant_name(["--foo", "bar"])
    assert_match(/unknown flag --foo/, problems.first)
    refute_match(/--name/, problems.first)
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
      report_arg_problems("snooze", ["--app is required"], usage_for("invariants snooze"))
    end
    assert_equal 1, status
    assert_match(/snooze: --app is required/, out)
    assert_match(/Usage: dev invariants snooze <name>/, out)
  end

  def test_report_multiple_problems_are_bulleted
    out, status = capture_stderr_and_exit do
      report_arg_problems("snooze", ["--app is required", "--days is required"], usage_for("invariants snooze"))
    end
    assert_equal 1, status
    assert_match(/snooze: 2 problems:/, out)
    assert_match(/^  - --app is required$/, out)
    assert_match(/^  - --days is required$/, out)
  end

  def test_report_empty_problems_is_noop
    out, status = capture_stderr_and_exit { report_arg_problems("snooze", [], usage_for("invariants snooze")) }
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
    assert_match(/positional argument — pass it without a flag/, out)
  end

  def test_snooze_missing_only_app_reports_it_with_rationale
    # --app moved from a dedicated Util.exit_with_error into the batched report;
    # pin that it still surfaces as the single problem, with the safety rationale.
    args = ["my_invariant", "--days", "10", "--reason", "test"]
    out, status = capture_stderr_and_exit { cmd_invariants_snooze(args) }
    assert_equal 1, status
    assert_match(/snooze: --app is required \(mutations must target a single app\)/, out)
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

# Rendering the `created_by` audit union returned by GET /dev/invariant/snoozes.
# Keyed off the discriminator: "person" shows name and/or email (fallback to id),
# "reference" shows the opaque user id, any other variant is shown verbatim.
class TestFormatCreatedBy < Minitest::Test
  def person(fields)
    { 'discriminator' => 'person', 'person' => fields }
  end

  def test_person_with_name_and_email
    cb = person('id' => 'per-1', 'name' => 'Jane Doe', 'email' => { 'address' => 'jane@example.com' })
    assert_equal 'Jane Doe <jane@example.com>', format_created_by(cb)
  end

  def test_person_with_email_only
    cb = person('id' => 'per-2', 'email' => { 'address' => 'bob@example.com' })
    assert_equal '<bob@example.com>', format_created_by(cb)
  end

  def test_person_with_name_only
    cb = person('id' => 'per-3', 'name' => 'No Email')
    assert_equal 'No Email', format_created_by(cb)
  end

  def test_person_with_neither_falls_back_to_person_id
    cb = person('id' => 'per-4')
    assert_equal 'per-4', format_created_by(cb)
  end

  def test_person_blank_name_and_email_are_ignored
    cb = person('id' => 'per-5', 'name' => '  ', 'email' => { 'address' => '' })
    assert_equal 'per-5', format_created_by(cb)
  end

  def test_person_fully_empty_falls_back_to_unknown
    cb = person({})
    assert_equal 'unknown', format_created_by(cb)
  end

  def test_reference_shows_user_id
    cb = { 'discriminator' => 'reference', 'user' => { 'id' => 'usr-109fd8' } }
    assert_equal 'usr-109fd8', format_created_by(cb)
  end

  def test_unknown_discriminator_is_shown_verbatim
    assert_equal 'future_thing', format_created_by('discriminator' => 'future_thing')
  end

  def test_missing_discriminator_falls_back_to_unknown
    assert_equal 'unknown', format_created_by({})
  end
end
