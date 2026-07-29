#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the investigation hand-off on `dev invariants check`: which failures are
# worth a session, what the prompt handed to that session contains, and the
# shape of the multi-app fan-out. The launch itself execs, so everything here
# exercises the pure seams that build what it would exec.
class TestDevInvariantsFix < Minitest::Test
  include DevTestSupport

  def endpoint_result(name, data: nil, error: nil)
    { endpoint: ApiClient::ENDPOINTS.find { |e| e[:name] == name }, data: data, error: error }
  end

  def failing_names(failing)
    failing.map { |endpoint, _| endpoint[:name] }
  end

  def platform_endpoint_hash
    ApiClient::ENDPOINTS.find { |e| e[:name] == "Platform" }
  end

  def failing_data(name: "some_invariant", count: 3, examples: nil, errors: [], passed: 100)
    {
      "success" => Array.new(passed) { |i| { "name" => "ok_#{i}" } },
      "non_zero" => [{ "name" => name, "count" => count, "examples" => examples }].compact,
      "error" => errors,
    }
  end

  # ---- invariants_failing_apps: only failures with data behind them ----

  def test_app_with_non_zero_count_is_offered
    failing = invariants_failing_apps([endpoint_result("Platform", data: failing_data)])
    assert_equal ["Platform"], failing_names(failing)
  end

  def test_app_with_an_errored_invariant_is_offered
    data = { "success" => [], "non_zero" => [], "error" => [{ "name" => "x", "error" => "boom" }] }
    failing = invariants_failing_apps([endpoint_result("Acumen", data: data)])
    assert_equal ["Acumen"], failing_names(failing)
  end

  def test_passing_app_is_not_offered
    data = { "success" => [{ "name" => "ok" }], "non_zero" => [], "error" => [] }
    assert_empty invariants_failing_apps([endpoint_result("Acumen", data: data)])
  end

  # An unreachable app is an auth/infra problem, not a data problem. Launching a
  # session at it hands it nothing to investigate — the check never ran.
  def test_unreachable_app_is_not_offered
    results = [endpoint_result("Platform", error: "session expired - run 'dev auth login'")]
    assert_empty invariants_failing_apps(results)
  end

  def test_only_the_failing_app_is_offered_when_another_passes
    results = [
      endpoint_result("Platform", data: failing_data),
      endpoint_result("Acumen", data: { "success" => [{ "name" => "ok" }], "non_zero" => [], "error" => [] }),
    ]
    assert_equal ["Platform"], failing_names(invariants_failing_apps(results))
  end

  def test_failing_apps_are_sorted_by_name
    results = [
      endpoint_result("Platform", data: failing_data),
      endpoint_result("Acumen", data: failing_data),
    ]
    assert_equal %w[Acumen Platform], failing_names(invariants_failing_apps(results))
  end

  # ---- invariants_app_prompt ----

  def test_app_prompt_names_the_app_and_its_failure_counts
    prompt = invariants_app_prompt(platform_endpoint_hash, failing_data(passed: 359))
    assert_includes prompt, "failing for Platform"
    assert_includes prompt, "(1 failing invariant(s) of 360 total)"
  end

  # The re-run command the session is told to use must actually work. Today every
  # endpoint's :app happens to equal its downcased :name, so this pins the intent
  # rather than catching a regression — it starts catching one the moment an
  # endpoint is added whose display name is not its --app key.
  def test_app_prompt_rerun_command_uses_the_endpoint_app_key
    prompt = invariants_app_prompt(platform_endpoint_hash, failing_data)
    assert_includes prompt, "dev invariants check --app platform"
  end

  def test_app_prompt_carries_the_failure_block_verbatim
    data = failing_data(name: "club_missing_insight", count: 1, examples: ["club picklejar"])
    prompt = invariants_app_prompt(platform_endpoint_hash, data)
    assert_includes prompt, "  - club_missing_insight"
    assert_includes prompt, "    Count: 1"
    assert_includes prompt, "      * club picklejar"
  end

  # The terminal truncates examples to stay readable; the session must not be,
  # because whether 1 or 400 rows fail is often the whole diagnosis.
  def test_app_prompt_includes_every_example_not_just_the_first_ten
    data = failing_data(count: 25, examples: (1..25).map { |i| "row-#{i}" })
    prompt = invariants_app_prompt(platform_endpoint_hash, data)
    assert_includes prompt, "      * row-25"
    refute_includes prompt, "... and"
  end

  def test_app_prompt_appends_the_durable_body
    prompt = invariants_app_prompt(platform_endpoint_hash, failing_data)
    assert_includes prompt, "Classify before you fix"
    assert_includes prompt, "NEVER fabricate, backfill, or zero-fill data"
  end

  # The body file is the editable half of the prompt; a rename or a bad path
  # would otherwise only surface when a real failure tried to launch a session.
  def test_body_file_is_readable
    refute_empty invariants_body_text.strip
  end

  # ---- launch prompt: one app direct, several fanned out ----

  def test_single_app_launch_prompt_is_that_apps_brief
    prompt = invariants_launch_prompt([["Platform", "PLATFORM BRIEF"]])
    assert_includes prompt, "PLATFORM BRIEF"
    refute_includes prompt, "subagent"
  end

  def test_multi_app_launch_prompt_dispatches_one_subagent_per_app
    prompt = invariants_launch_prompt([["Acumen", "ACUMEN BRIEF"], ["Platform", "PLATFORM BRIEF"]])
    assert_includes prompt, "ONE subagent per app"
    assert_includes prompt, "===== Acumen ====="
    assert_includes prompt, "ACUMEN BRIEF"
    assert_includes prompt, "===== Platform ====="
    assert_includes prompt, "PLATFORM BRIEF"
  end

  def test_launch_prompt_sets_a_tab_title_naming_the_apps
    prompt = invariants_launch_prompt([["Acumen", "a"], ["Platform", "p"]])
    assert_includes prompt, 'Set the terminal tab title to "Invariants: Acumen, Platform"'
  end

  # ---- the offer itself ----

  # A cron or piped run must report and exit, never block on a prompt nobody can
  # answer — and must never exec a session behind Mike's back.
  def test_no_offer_and_no_launch_when_stdin_is_not_a_tty
    launched = with_stubbed_launch(tty: false) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], false)
    end
    assert_nil launched
  end

  def test_interactive_yes_launches
    launched = with_stubbed_launch(tty: true, answer: true) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], false)
    end
    assert_includes launched, "failing for Platform"
  end

  def test_interactive_no_does_not_launch
    launched = with_stubbed_launch(tty: true, answer: false) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], false)
    end
    assert_nil launched
  end

  # --fix is the explicit opt-in, so it launches without a tty to ask on.
  def test_auto_fix_launches_without_asking
    launched = with_stubbed_launch(tty: false) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], true)
    end
    assert_includes launched, "failing for Platform"
  end

  def test_auto_fix_does_not_launch_when_nothing_has_data
    launched = with_stubbed_launch(tty: false) do
      invariants_offer_investigation([endpoint_result("Platform", error: "unreachable")], true)
    end
    assert_nil launched
  end

  # Returns the prompt `exec_claude` would have run, or nil if it was never
  # reached. Both the tty check and the confirmation are stubbed so the test does
  # not depend on how the suite itself was invoked, and `exec_claude` is replaced
  # so a launch cannot replace the test process.
  def with_stubbed_launch(tty:, answer: nil)
    captured = nil
    orig_exec = Object.instance_method(:exec_claude)
    orig_tty = Object.instance_method(:interactive_terminal?)
    orig_ask = Ask.method(:for_boolean)
    Object.send(:define_method, :exec_claude) { |prompt, **_kwargs| captured = prompt }
    Object.send(:define_method, :interactive_terminal?) { tty }
    Ask.define_singleton_method(:for_boolean) { |_msg| answer }
    capture_io { yield }
    captured
  ensure
    Object.send(:define_method, :exec_claude, orig_exec)
    Object.send(:define_method, :interactive_terminal?, orig_tty)
    Ask.define_singleton_method(:for_boolean, orig_ask)
  end
end
