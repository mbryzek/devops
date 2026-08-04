#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers the investigation hand-off on `dev invariants check`: which failures are
# worth a session, what the prompt handed to that session contains, the shape of
# the multi-app fan-out, and which of the two launch paths (interactive exec vs
# headless unattended dispatch) a given tty/--fix combination takes. Launching
# either for real would replace or fork the test process, so everything here
# exercises the pure seams that build what would be launched.
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

  # ---- invariants_exit_code: the producer contract in agent/producers.yml ----
  #
  # ISS-358: an expired session made the check exit 1, so the `invariants-platform`
  # producer filed a high-severity issue for a check that had fetched nothing. Worse
  # than the wasted session, that issue then held the `invariants:platform`
  # fingerprint, and `Agent::Producers.in_flight?` blocks a producer from filing while
  # a non-terminal issue with its fingerprint exists — so for as long as the session
  # stayed expired, every REAL platform invariant failure was silently unfilable.

  def clean_data
    { "success" => [{ "name" => "ok" }], "non_zero" => [], "error" => [] }
  end

  def test_all_clean_exits_zero
    assert_equal 0, invariants_exit_code([endpoint_result("Platform", data: clean_data)])
  end

  def test_real_findings_exit_one
    assert_equal 1, invariants_exit_code([endpoint_result("Platform", data: failing_data)])
  end

  # The regression itself: nothing was checked, so this is not a finding.
  def test_expired_session_exits_two_not_one
    results = [endpoint_result("Platform", error: "session expired - run 'dev auth login'")]
    assert_equal 2, invariants_exit_code(results)
  end

  def test_unreachable_app_exits_two_not_one
    results = [endpoint_result("Platform", error: "Connection refused")]
    assert_equal 2, invariants_exit_code(results)
  end

  # Findings outrank an unreachable sibling. Returning 2 here would send a real data
  # problem down the tick's `check_failed` path, which files nothing at all.
  def test_findings_win_over_an_unreachable_app
    results = [
      endpoint_result("Platform", data: failing_data),
      endpoint_result("Acumen", error: "session expired - run 'dev auth login'"),
    ]
    assert_equal 1, invariants_exit_code(results)
  end

  # A passing app does not launder an unreachable one into a clean run: the app that
  # errored still checked nothing, and 0 would report all-clear on unread data.
  def test_unreachable_app_alongside_a_passing_one_still_exits_two
    results = [
      endpoint_result("Platform", error: "session expired - run 'dev auth login'"),
      endpoint_result("Acumen", data: clean_data),
    ]
    assert_equal 2, invariants_exit_code(results)
  end

  # An invariant that errored server-side DID run and has data behind it — unlike a
  # failed request. It stays a finding.
  def test_an_errored_invariant_is_a_finding_not_an_unchecked_run
    data = { "success" => [], "non_zero" => [], "error" => [{ "name" => "x", "error" => "boom" }] }
    assert_equal 1, invariants_exit_code([endpoint_result("Platform", data: data)])
  end

  # The tick reads `>1`, not `== 2` (lib/agent/tick.rb), and producers.yml documents
  # the same. Pin the three constants to the contract they encode.
  def test_exit_constants_match_the_documented_contract
    assert_equal 0, INVARIANTS_EXIT_CLEAN
    assert_equal 1, INVARIANTS_EXIT_FINDINGS
    assert_operator INVARIANTS_EXIT_UNCHECKABLE, :>, 1
  end

  # ---- invariant_checks_path: what the CLI actually asks the server for ----

  # ISS-173: the endpoint took no parameter and capped examples at 10 server-side,
  # so --examples/--all-examples could only ever narrow the same 10 rows. The fix
  # is only real if the request itself carries the cap.
  def test_checks_path_requests_the_server_example_cap
    assert_equal "/dev/invariant/checks?examples=#{INVARIANT_EXAMPLES_MAX}", invariant_checks_path
  end

  # The help text quotes the cap; it must quote the one actually requested.
  def test_usage_documents_the_cap_that_is_requested
    assert_includes USAGE, "caps examples at #{INVARIANT_EXAMPLES_MAX} per invariant"
  end

  # ---- invariant_failure_lines: the terminal truncates, the session does not ----

  def test_terminal_truncates_examples_and_reports_how_many_more
    lines = invariant_failure_lines(failing_data(count: 30, examples: (1..30).map { |i| "row-#{i}" }))
    assert_includes lines, "      * row-10"
    refute_includes lines, "      * row-11"
    assert_includes lines, "      ... and 20 more"
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

  # A session that does not know these exist writes a migration, or hand-patches
  # rows, for something a shipped command already does. Each is named because the
  # investigating session is the one consumer that never gets to read `dev help`.
  def test_body_names_the_remediation_commands
    body = invariants_body_text
    ["dev tasks requeue", "dev tasks delete --id", "dev tasks delete --discriminator",
     "dev invariants snooze"].each do |command|
      assert_includes body, command, "remediation playbook no longer names `#{command}`"
    end
  end

  # unknown_task_discriminators is the one failure whose whole remedy is a delete,
  # and the one where deleting the wrong thing destroys real queued work.
  def test_body_pairs_the_queue_wipe_with_its_invariant_and_its_caveat
    body = invariants_body_text
    assert_includes body, "unknown_task_discriminators"
    assert_match(/vanish by ACCIDENT/, body)
  end

  # The standing rule is GitHub only; the body used to tell every investigating
  # session to hand back a Reviewable URL.
  def test_body_does_not_ask_for_a_reviewable_url
    refute_match(/Report the Reviewable URL/, invariants_body_text)
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

  # --fix at a terminal skips the question but still hands the terminal over.
  def test_auto_fix_launches_without_asking
    launched = with_stubbed_launch(tty: true) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], true)
    end
    assert_includes launched, "failing for Platform"
  end

  def test_auto_fix_does_not_launch_when_nothing_has_data
    launched = with_stubbed_launch(tty: true) do
      invariants_offer_investigation([endpoint_result("Platform", error: "unreachable")], true)
    end
    assert_nil launched
  end

  # ---- unattended dispatch (the cron path) ----

  def test_no_tty_without_fix_does_not_dispatch
    dispatched = with_stubbed_dispatch(tty: false) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], false)
    end
    assert_nil dispatched
  end

  def test_no_tty_with_fix_dispatches_headless
    dispatched = with_stubbed_dispatch(tty: false) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], true)
    end
    assert_equal ["Platform"], dispatched.map { |endpoint, _| endpoint[:name] }
  end

  # A tty means a human is here, so even --fix takes the interactive path — the
  # terminal hand-off, not a detached session writing to a log nobody opens.
  def test_tty_with_fix_execs_instead_of_dispatching
    dispatched = with_stubbed_dispatch(tty: true) do
      invariants_offer_investigation([endpoint_result("Platform", data: failing_data)], true)
    end
    assert_nil dispatched
  end

  # ---- headless argv + prompt ----

  def test_headless_argv_is_print_mode_on_opus_5
    argv = headless_claude_argv("do the thing")
    assert_equal "claude", argv[0]
    assert_includes argv, "--print"                             # no terminal to attach to
    assert_includes argv, "--dangerously-skip-permissions"      # nobody to answer prompts
    assert_equal "claude-opus-5[1m]", argv[argv.index("--model") + 1]
    assert_equal "do the thing", argv.last
  end

  def test_unattended_suffix_demands_a_durable_artifact_and_an_announcement
    suffix = invariants_unattended_suffix
    assert_includes suffix, "~/code/claude/plans/"
    assert_includes suffix, "openclaw system event"
    assert_includes suffix, "dev invariants snooze"
  end

  # ---- dedupe: the same failures must not spawn a session every night ----

  def test_same_failures_within_the_window_are_deduped
    now = Time.parse("2026-07-29T06:14:00Z")
    state = { "platform" => { "invariants" => %w[a b], "at" => (now - 24 * 60 * 60).iso8601 } }
    assert invariants_recently_dispatched?(state, "platform", %w[a b], now)
  end

  def test_same_failures_past_the_window_are_dispatched_again
    now = Time.parse("2026-07-29T06:14:00Z")
    old = (now - (INVARIANTS_REDISPATCH_DAYS + 1) * 24 * 60 * 60).iso8601
    state = { "platform" => { "invariants" => %w[a b], "at" => old } }
    refute invariants_recently_dispatched?(state, "platform", %w[a b], now)
  end

  # A changed set of failures is new information, whatever is already in flight.
  def test_a_different_failure_set_is_not_deduped
    now = Time.parse("2026-07-29T06:14:00Z")
    state = { "platform" => { "invariants" => %w[a b], "at" => now.iso8601 } }
    refute invariants_recently_dispatched?(state, "platform", %w[a b c], now)
    refute invariants_recently_dispatched?(state, "platform", %w[a], now)
  end

  def test_a_different_app_is_not_deduped
    now = Time.parse("2026-07-29T06:14:00Z")
    state = { "platform" => { "invariants" => %w[a], "at" => now.iso8601 } }
    refute invariants_recently_dispatched?(state, "acumen", %w[a], now)
  end

  # Never let a bad marker file suppress a dispatch: one duplicate session is a
  # far cheaper failure than silence on a real invariant.
  def test_unknown_app_and_unparseable_timestamp_dispatch
    now = Time.parse("2026-07-29T06:14:00Z")
    refute invariants_recently_dispatched?({}, "platform", %w[a], now)
    state = { "platform" => { "invariants" => %w[a], "at" => "not a date" } }
    refute invariants_recently_dispatched?(state, "platform", %w[a], now)
  end

  def test_invariant_names_are_sorted_and_span_both_failure_kinds
    data = {
      "success" => [],
      "non_zero" => [{ "name" => "zebra" }],
      "error" => [{ "name" => "apple", "error" => "boom" }],
    }
    assert_equal %w[apple zebra], invariant_names(data)
  end

  # Captures what `invariants_dispatch_unattended` was called with instead of
  # spawning real sessions. Returns nil when the unattended path was not taken.
  def with_stubbed_dispatch(tty:)
    captured = nil
    orig_dispatch = Object.instance_method(:invariants_dispatch_unattended)
    orig_exec = Object.instance_method(:exec_claude)
    orig_tty = Object.instance_method(:interactive_terminal?)
    Object.send(:define_method, :invariants_dispatch_unattended) { |failing, **_kwargs| captured = failing }
    Object.send(:define_method, :exec_claude) { |_prompt, **_kwargs| nil }
    Object.send(:define_method, :interactive_terminal?) { tty }
    capture_io { yield }
    captured
  ensure
    Object.send(:define_method, :invariants_dispatch_unattended, orig_dispatch)
    Object.send(:define_method, :exec_claude, orig_exec)
    Object.send(:define_method, :interactive_terminal?, orig_tty)
  end

  # Returns the prompt `exec_claude` would have run, or nil if it was never
  # reached. The tty check and the confirmation are stubbed so the test does not
  # depend on how the suite itself was invoked, and BOTH launch paths are
  # replaced: `exec_claude` so a launch cannot replace the test process, and the
  # unattended dispatch so no test can ever spawn a real `claude --print`.
  def with_stubbed_launch(tty:, answer: nil)
    captured = nil
    orig_exec = Object.instance_method(:exec_claude)
    orig_dispatch = Object.instance_method(:invariants_dispatch_unattended)
    orig_tty = Object.instance_method(:interactive_terminal?)
    orig_ask = Ask.method(:for_boolean)
    Object.send(:define_method, :exec_claude) { |prompt, **_kwargs| captured = prompt }
    Object.send(:define_method, :invariants_dispatch_unattended) { |_failing, **_kwargs| [] }
    Object.send(:define_method, :interactive_terminal?) { tty }
    Ask.define_singleton_method(:for_boolean) { |_msg| answer }
    capture_io { yield }
    captured
  ensure
    Object.send(:define_method, :exec_claude, orig_exec)
    Object.send(:define_method, :invariants_dispatch_unattended, orig_dispatch)
    Object.send(:define_method, :interactive_terminal?, orig_tty)
    Ask.define_singleton_method(:for_boolean, orig_ask)
  end
end
