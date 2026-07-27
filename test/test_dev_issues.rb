#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev issues {claim,status,reconcile}`: the pure plan-rendering helpers (no
# network), the claim/status arg validation, and the playbook credential guard.
# Network paths (claim/status HTTP) are not exercised here — they exit before any
# request when args or credentials are missing.
class TestDevIssues < Minitest::Test
  include DevTestSupport

  # Run a block as if `dev auth login --app playbook` had never been run. Guards the
  # arg-validation tests: this box has a real playbook session, so without it a
  # command that gets past validation would fire a live request at production.
  def without_playbook_session
    orig = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:session_id_for) do |app, use_localhost:|
      app == "playbook" ? nil : orig.call(app, use_localhost: use_localhost)
    end
    yield
  ensure
    ApiClient.define_singleton_method(:session_id_for, orig)
  end

  def graph_issue
    {
      "id" => "iss-1",
      "tenant" => { "id" => "playbook" },
      "number" => "034",
      "category" => "graphs",
      "status" => "claimed",
      "severity" => "high",
      "title" => "Bars overflow the axis",
      "body" => "Revenue by type renders past the plot area",
      "created" => { "at" => "2026-07-10T12:00:00Z", "by" => { "id" => "usr-1", "name" => "Mike Bryzek" } },
      "club" => { "id" => "club-9", "name" => "Padel Haus" },
      "attachments" => [
        { "file" => { "id" => "f-1", "url" => "https://img/shot.png" }, "description" => "page /graphs/financial?range=ytd · 1440x900" },
      ],
      "occurrence_count" => 1,
    }
  end

  # Fleet-wide auto-filed issue: no club, no attachments, recurring fingerprint.
  def crawl_issue
    {
      "id" => "iss-2",
      "number" => "035",
      "category" => "worker",
      "status" => "open",
      "title" => "Members export empty for 3 clubs",
      "created" => { "at" => "2026-07-09T08:30:00Z", "by" => { "nickname" => "logreview" } },
      "fingerprint" => "cr-members-empty",
      "occurrence_count" => 4,
    }
  end

  # Child club (bare name "Baltimore") with a parent — ambiguous without it.
  def child_club_issue
    graph_issue.merge(
      "id" => "iss-3",
      "number" => "036",
      "club" => { "id" => "bounce-baltimore", "name" => "Baltimore", "parent" => { "id" => "bounce", "name" => "Bounce" } },
    )
  end

  def fixed_issue(deployment: { "app" => "playbook-app", "baseline_version" => "0.1.4" })
    graph_issue.merge(
      "status" => "fixed",
      "fixed_at" => "2026-07-10T09:00:00Z",
      "fixes" => [{ "url" => "https://github.com/mbryzek/playbook-app/pull/1", "deployment" => deployment }.compact],
    )
  end

  # ---- issue_label ----

  def test_issue_label_is_iss_prefixed_number
    assert_equal "ISS-034", issue_label(graph_issue)
  end

  # ---- issue_render_item ----

  def test_render_item_with_club_and_attachment
    out = issue_render_item(graph_issue, 1)
    assert_includes out, "### 1. ISS-034 — Bars overflow the axis"
    assert_includes out, "- Issue: `ISS-034` (id `iss-1`)"
    assert_includes out, "- Category: graphs"
    assert_includes out, "- Status: claimed"
    assert_includes out, "- Severity: high"
    assert_includes out, "- Club: Padel Haus (`club-9`)"
    assert_includes out, "- Created: 2026-07-10T12:00:00Z by Mike Bryzek"
    assert_includes out, "- Attachments: https://img/shot.png (page /graphs/financial?range=ytd · 1440x900)"
    assert_includes out, "> Revenue by type renders past the plot area"
  end

  def test_render_item_missing_optionals
    out = issue_render_item(crawl_issue, 2)
    assert_includes out, "### 2. ISS-035 — Members export empty for 3 clubs"
    assert_includes out, "- Severity: unspecified"
    assert_includes out, "- Attachments: none"
    assert_includes out, "- Occurrences: 4"
    assert_includes out, "- Fingerprint: `cr-members-empty`"
    assert_includes out, "by logreview"
    refute_includes out, "- Club:", "no club on a fleet-wide auto-filed issue"
  end

  def test_render_item_quotes_multiline_body
    out = issue_render_item(graph_issue.merge("body" => "line one\nline two"), 1)
    assert_includes out, "> line one\n> line two"
  end

  def test_render_item_prefixes_parent_club
    out = issue_render_item(child_club_issue, 1)
    assert_includes out, "- Club: Bounce / Baltimore (`bounce-baltimore`)"
  end

  # ---- issue_club_label ----

  def test_club_label_prefixes_parent_when_present
    assert_equal "Bounce / Baltimore", issue_club_label(child_club_issue)
  end

  def test_club_label_bare_name_without_parent
    assert_equal "Padel Haus", issue_club_label(graph_issue)
  end

  def test_club_label_falls_back_to_id_then_placeholder
    assert_equal "club-x", issue_club_label("club" => { "id" => "club-x" })
    assert_equal "?", issue_club_label({})
  end

  # ---- issue_plan_markdown ----

  def test_plan_markdown_structure
    md = issue_plan_markdown(items: [graph_issue, child_club_issue], date: "2026-07-10", category: "graphs", body: "BODY-ORIENTATION")
    assert_includes md, "# graphs issues — 2 item(s) claimed 2026-07-10"
    assert_includes md, "`dev issues claim --category graphs`"
    assert_includes md, "## Issues to fix"
    assert_includes md, "### 1. ISS-034 — Bars overflow the axis"
    assert_includes md, "### 2. ISS-036 — Bars overflow the axis"
    assert_includes md, "BODY-ORIENTATION"
    assert_includes md, "## Closing each issue"
    assert_includes md, 'dev issues status <number> --status fixed --url "<PR URL>" --app <deployable-app> --baseline-version <live version>'
    assert_includes md, 'dev issues status <number> --status fixed --url "<doc URL>"'
    assert_includes md, "--status needs_input"
  end

  # ---- issue_summary_line ----

  def test_summary_line_shows_number_status_club_and_title
    assert_equal "  1. ISS-034 · claimed · Padel Haus · Bars overflow the axis",
                 issue_summary_line(graph_issue, 1)
  end

  def test_summary_line_omits_category_because_lines_print_under_a_category_heading
    refute_includes issue_summary_line(graph_issue, 1), "graphs"
  end

  def test_summary_line_omits_club_when_absent
    assert_equal "  2. ISS-035 · open · Members export empty for 3 clubs",
                 issue_summary_line(crawl_issue, 2)
  end

  def test_summary_line_truncates_long_title
    line = issue_summary_line(graph_issue.merge("title" => "x" * 200), 3)
    assert_includes line, "..."
    assert line.length < 120, "summary line should be truncated: #{line.length}"
  end

  def test_summary_line_prefixes_parent_club
    assert_includes issue_summary_line(child_club_issue, 4), "  4. ISS-036 · claimed · Bounce / Baltimore · "
  end

  # ---- per-category body files are real and reachable ----

  # Categories with a pipeline of their own — these keep a dedicated body file.
  PIPELINE_CATEGORIES = %w[graphs worker insights].freeze

  def test_pipeline_categories_have_their_own_body_file
    PIPELINE_CATEGORIES.each do |category|
      body = issue_body_text(category)
      assert_includes body, "## How this pipeline works", "#{category}: missing pipeline map"
      assert_includes body, "## Working rules", "#{category}: missing working rules"
    end
  end

  # Every claimable category must render a plan body. A missing <category>-body.md
  # used to raise Errno::ENOENT mid-claim, AFTER the issues were already flipped to
  # `claimed` server-side — leaving them claimed with no plan.
  def test_every_category_resolves_to_a_body
    ISSUE_CATEGORIES.each do |category|
      refute_empty issue_body_text(category).strip, "#{category}: empty body"
    end
  end

  def test_non_pipeline_categories_fall_back_to_the_default_body
    (ISSUE_CATEGORIES - PIPELINE_CATEGORIES).each do |category|
      assert_equal issue_default_body_text, issue_body_text(category), "#{category}: expected default body"
    end
  end

  # A category added to the spec enum before anyone writes its body file still
  # claims — it just gets the generic guide.
  def test_unknown_category_falls_back_to_the_default_body
    assert_equal issue_default_body_text, issue_body_text("brand-new-category")
  end

  def test_default_body_carries_the_shared_working_rules
    body = issue_default_body_text
    assert_includes body, "## How to work"
    assert_includes body, "~/code/ai/"          # feature-dir rule
    assert_includes body, "needs_input"         # what to do when a human call is needed
  end

  # The working rules live in default-body.md ONLY; the manual body is the
  # hand-filed preamble that gets prepended to it.
  def test_manual_body_is_composed_from_the_default_body
    body = issue_manual_body_text
    assert_includes body, "Working a hand-filed issue"
    assert_includes body, issue_default_body_text.strip
    assert_equal 1, body.scan("## How to work").length, "working rules duplicated"
  end

  def test_categories_match_the_spec_enum
    assert_equal %w[graphs worker insights suggestion feature bug improvement], ISSUE_CATEGORIES
  end

  def test_graphs_body_orients_to_playbook_app
    assert_includes issue_body_text("graphs"), "mbryzek/playbook-app"
  end

  def test_worker_body_orients_to_the_crawl_pipeline
    body = issue_body_text("worker")
    assert_includes body, "mbryzek/workers"           # the browser scraper
    assert_includes body, "courtreserve"              # the platform ingest/parse package
    assert_includes body, "log review"                # where these issues come from
  end

  def test_insights_body_orients_to_generation_quality
    body = issue_body_text("insights")
    assert_includes body, "playbook"                  # the generation subproject
    assert_includes body, "mbryzek/playbook-admin"    # where insights are reviewed
    assert_includes body, "checklist"                 # rejected-checklist-item feedback
  end

  # ---- issues list path filters by `statuses` (plural), never `status` ----
  # Regression: the singular `status=open` is an unknown query parameter the
  # server ignores, so the claim preview and reconcile scan saw EVERY status
  # instead of just open/fixed. The spec parameter is the repeatable `statuses`.

  def test_issues_list_path_uses_plural_statuses_param
    path = issues_list_path(statuses: "open", category: "graphs")
    assert_includes path, "statuses=open"
    refute_includes path, "status=open"   # the singular, server-ignored form
    assert_includes path, "categories=graphs"
    assert_includes path, "limit=100"
    assert_includes path, "offset=0"
  end

  def test_issues_list_path_omits_category_when_absent
    path = issues_list_path(statuses: "fixed")
    assert_includes path, "statuses=fixed"
    refute_includes path, "categories="
  end

  # ---- spawned-session command (interactive Opus 4.8 / 1M) ----

  def test_issue_session_prompt_names_the_plan
    assert_equal "read the plan at /p/x.md and implement it", issue_session_prompt("/p/x.md")
  end

  def test_issue_claude_command_is_ccd_pinned_to_opus_1m
    cmd = issue_claude_command("/p/x.md")
    assert_equal "claude", cmd[0]
    assert_includes cmd, "--dangerously-skip-permissions"          # the `ccd` alias
    assert_equal "claude-opus-4-8[1m]", cmd[cmd.index("--model") + 1]
    assert_equal issue_session_prompt("/p/x.md"), cmd.last          # prompt is the final arg
  end

  # ---- tab title: the spawned session names its window after the issue(s) ----

  def test_tab_title_single_issue_is_labelled_and_titled
    assert_equal "ISS-034: Bars overflow the axis", issue_tab_title([graph_issue])
  end

  def test_tab_title_two_issues_are_joined_with_an_ampersand
    assert_equal "Issues: 034 & 035", issue_tab_title([graph_issue, crawl_issue])
  end

  def test_tab_title_three_or_more_issues_are_comma_separated
    issues = [graph_issue, crawl_issue, crawl_issue.merge("number" => "036")]
    assert_equal "Issues: 034, 035 & 036", issue_tab_title(issues)
  end

  def test_tab_title_is_nil_when_nothing_was_claimed
    assert_nil issue_tab_title([])
  end

  # The title lands inside a double-quoted shell argument in the prompt, so a
  # quote (or a newline) in the issue title must not break out of it.
  def test_tab_title_strips_quotes_newlines_and_truncates
    messy = graph_issue.merge("title" => "Say \"hi\"\nto  the\\ axis")
    assert_equal "ISS-034: Say 'hi' to the' axis", issue_tab_title([messy])
    long = graph_issue.merge("title" => "x" * 100)
    assert_equal 60, issue_tab_title([long]).sub("ISS-034: ", "").length
  end

  def test_prompt_with_tab_title_prefixes_the_work_prompt
    prompt = issue_prompt_with_tab_title([graph_issue], issue_session_prompt("/p/x.md"))
    assert_includes prompt, 'tab title to "ISS-034: Bars overflow the axis"'
    assert prompt.end_with?(issue_session_prompt("/p/x.md")), prompt
  end

  def test_prompt_with_tab_title_is_untouched_without_issues
    assert_equal issue_session_prompt("/p/x.md"), issue_prompt_with_tab_title([], issue_session_prompt("/p/x.md"))
  end

  # ---- claim prompt: one plan works directly, several fan out subagents ----

  def test_claim_prompt_single_plan_is_todays_direct_prompt
    assert_equal issue_session_prompt("/p/g.md"), issue_claim_prompt([["graphs", "/p/g.md"]])
  end

  def test_claim_prompt_multi_plan_dispatches_one_subagent_per_plan
    prompt = issue_claim_prompt([["graphs", "/p/g.md"], ["worker", "/p/w.md"]])
    assert_includes prompt, "2 issue plans"
    assert_includes prompt, "ONE subagent per plan"
    assert_includes prompt, "do NOT implement the fixes yourself"
    assert_includes prompt, "- graphs: /p/g.md"
    assert_includes prompt, "- worker: /p/w.md"
  end

  def test_claim_argv_wraps_any_prompt_as_ccd_opus
    argv = issue_claude_argv("do the thing")
    assert_equal "claude", argv[0]
    assert_includes argv, "--dangerously-skip-permissions"
    assert_equal "claude-opus-4-8[1m]", argv[argv.index("--model") + 1]
    assert_equal "do the thing", argv.last
  end

  # ---- issue_categories_present: enum-ordered, nothing filtered out ----

  def test_categories_present_returns_enum_order
    open = [crawl_issue.merge("category" => "insights"), graph_issue.merge("status" => "open"), crawl_issue]
    # graphs (from graph_issue) + worker (crawl_issue) + insights, listed in enum order.
    assert_equal %w[graphs worker insights], issue_categories_present(open)
  end

  # Regression: `suggestion` (and the hand-filed feature/bug/improvement) used to
  # be filtered out of the claim sweep, so an open suggestion reported
  # "No open issues." and could never be claimed from the CLI.
  def test_categories_present_includes_suggestion_and_manual_categories
    open = %w[suggestion feature bug improvement].map { |c| crawl_issue.merge("category" => c) }
    assert_equal %w[suggestion feature bug improvement], issue_categories_present(open)
  end

  # A category the tracker knows but this script does not (added to the spec enum
  # since) is still claimed — listed after the known ones rather than dropped.
  def test_categories_present_keeps_unknown_categories_last
    open = [crawl_issue.merge("category" => "mystery"), graph_issue.merge("status" => "open")]
    assert_equal %w[graphs mystery], issue_categories_present(open)
  end

  def test_categories_present_empty_only_when_nothing_is_open
    assert_empty issue_categories_present([])
  end

  # ---- cmd_issues_claim arg validation (exits before any network) ----

  # No --category is now valid (claim across all categories). Prove it gets PAST
  # arg validation by running with no playbook session so it stops at the
  # credential guard rather than firing a live claim at production.
  def test_claim_without_category_passes_arg_validation
    out, status = without_playbook_session { capture_stderr_and_exit { cmd_issues_claim([]) } }
    refute_match(/--category is required/, out)
    assert_equal 1, status
    assert_match(/dev auth login --app playbook/, out)
  end

  def test_claim_rejects_invalid_category
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--category", "bogus"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: graphs, worker, insights, suggestion, feature, bug, improvement/, out)
  end

  def test_claim_rejects_category_without_value
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--category"]) }
    assert_equal 1, status
    assert_match(/--category requires a value/, out)
  end

  def test_claim_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--category", "graphs", "extra"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  def test_claim_rejects_issues_without_value
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--issues"]) }
    assert_equal 1, status
    assert_match(/--issues requires a value/, out)
  end

  # ---- selecting which open issues to claim ----

  # The preview groups by category but the numbers the operator types must be
  # unambiguous across the whole list, so ordering is category-group order,
  # flattened, and indexes run 1..N.
  def open_queue
    [
      crawl_issue.merge("number" => "078", "category" => "worker", "status" => "open"),
      graph_issue.merge("number" => "079", "category" => "feature", "status" => "open"),
      graph_issue.merge("number" => "080", "category" => "improvement", "status" => "open"),
    ]
  end

  def ordered_queue
    present = issue_categories_present(open_queue)
    issue_ordered_open(open_queue, present)
  end

  def test_ordered_open_flattens_category_groups_in_enum_order
    assert_equal %w[078 079 080], ordered_queue.map { |c| c["number"] }
  end

  def test_selection_indexes_are_positions_in_the_flattened_list
    ordered = ordered_queue
    assert_equal %w[078 080], Ask.parse_selection("1,3", ordered).map { |c| c["number"] }
    assert_equal %w[078 079 080], Ask.parse_selection("all", ordered).map { |c| c["number"] }
    assert_empty Ask.parse_selection("none", ordered)
  end

  def test_requested_issues_accept_padded_unpadded_and_iss_prefixed_numbers
    resolved, unknown = issue_resolve_requested("078, 79, ISS-080", ordered_queue)
    assert_equal %w[078 079 080], resolved.map { |c| c["number"] }
    assert_empty unknown
  end

  def test_requested_issues_dedupe_and_report_what_is_not_on_offer
    resolved, unknown = issue_resolve_requested("078 078 999", ordered_queue)
    assert_equal %w[078], resolved.map { |c| c["number"] }
    assert_equal %w[999], unknown
  end

  # A category selected in full claims by category, so the server takes whatever
  # is open at claim time; a partial selection claims the exact numbers picked.
  def test_claim_scope_is_by_category_when_the_whole_category_is_selected
    worker = open_queue.select { |c| c["category"] == "worker" }
    assert_equal({ category: "worker" }, issue_claim_scope("worker", worker, worker))
  end

  def test_claim_scope_is_by_number_for_a_partial_selection
    graphs = [graph_issue.merge("number" => "090"), graph_issue.merge("number" => "091")]
    assert_equal({ numbers: %w[090] }, issue_claim_scope("graphs", [graphs.first], graphs))
  end

  # ---- categories a blanket claim never sweeps up ----

  def suggestion_queue
    open_queue + [graph_issue.merge("number" => "081", "category" => "suggestion", "status" => "open")]
  end

  def ordered_suggestion_queue
    issue_ordered_open(suggestion_queue, issue_categories_present(suggestion_queue))
  end

  def test_blanket_claim_skips_suggestions
    assert_equal %w[078 079 080], issue_auto_claim_default(ordered_suggestion_queue, nil).map { |c| c["number"] }
  end

  # Naming the category IS the human decision the gate exists for, so it stops
  # filtering and `all` means all again.
  def test_explicit_category_claims_suggestions
    ordered = ordered_suggestion_queue.select { |c| c["category"] == "suggestion" }
    assert_equal %w[081], issue_auto_claim_default(ordered, "suggestion").map { |c| c["number"] }
  end

  # A suggestion is still reachable by number — the gate is on the sweep, not on
  # the issue.
  def test_suggestions_are_still_selectable_by_number
    resolved, unknown = issue_resolve_requested("081", ordered_suggestion_queue)
    assert_equal %w[081], resolved.map { |c| c["number"] }
    assert_empty unknown
  end

  # `all` at the prompt means "what a sweep takes", not "everything listed".
  def test_prompt_all_takes_the_auto_claim_set_not_the_whole_list
    ordered = ordered_suggestion_queue
    auto = issue_auto_claim_default(ordered, nil)
    orig = Ask.method(:for_string)
    Ask.define_singleton_method(:for_string) { |_msg, _opts = {}| "all" }
    assert_equal %w[078 079 080], issue_ask_selection(ordered, auto).map { |c| c["number"] }
  ensure
    Ask.define_singleton_method(:for_string, orig)
  end

  def test_prompt_numbers_can_still_pick_a_suggestion
    ordered = ordered_suggestion_queue
    orig = Ask.method(:for_string)
    # suggestion sorts 2nd in ISSUE_CATEGORIES order: worker, suggestion, feature, improvement.
    Ask.define_singleton_method(:for_string) { |_msg, _opts = {}| "2" }
    assert_equal %w[081], issue_ask_selection(ordered, []).map { |c| c["number"] }
  ensure
    Ask.define_singleton_method(:for_string, orig)
  end

  # Even a whole-category suggestion pick claims by number: claiming by category
  # would take whatever is open server-side, pulling in a suggestion filed since
  # the preview that nobody looked at.
  def test_claim_scope_is_by_number_for_a_whole_suggestion_category
    suggestions = suggestion_queue.select { |c| c["category"] == "suggestion" }
    assert_equal({ numbers: %w[081] }, issue_claim_scope("suggestion", suggestions, suggestions))
  end

  # ---- cmd_issues_snooze arg validation (exits before any network) ----

  def test_snooze_requires_number
    out, status = capture_stderr_and_exit { cmd_issues_snooze(["--days", "1"]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
  end

  def test_snooze_requires_days_or_wake
    out, status = capture_stderr_and_exit { cmd_issues_snooze(["034"]) }
    assert_equal 1, status
    assert_match(/pass --days N or --wake/, out)
  end

  def test_snooze_rejects_days_with_wake
    out, status = capture_stderr_and_exit { cmd_issues_snooze(["034", "--days", "1", "--wake"]) }
    assert_equal 1, status
    assert_match(/opposites/, out)
  end

  def test_snooze_rejects_non_positive_days
    out, status = capture_stderr_and_exit { cmd_issues_snooze(["034", "--days", "0"]) }
    assert_equal 1, status
    assert_match(/--days must be an integer/, out)
  end

  # Valid args reach the credential guard rather than an arg complaint — the proof
  # that a well-formed snooze passes validation without this test hitting the network.
  def test_snooze_with_days_passes_arg_validation
    out, status = without_playbook_session do
      capture_stderr_and_exit { cmd_issues_snooze(["034", "--days", "1", "--comment", "confirm the migration"]) }
    end
    assert_equal 1, status
    assert_match(/No playbook session/, out)
  end

  # ---- cmd_issues_status arg validation (exits before any network) ----

  def test_status_requires_number
    out, status = capture_stderr_and_exit { cmd_issues_status(["--status", "dismissed"]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
  end

  def test_status_requires_status
    out, status = capture_stderr_and_exit { cmd_issues_status(["034"]) }
    assert_equal 1, status
    assert_match(/--status is required/, out)
  end

  def test_status_rejects_invalid_status
    out, status = capture_stderr_and_exit { cmd_issues_status(["034", "--status", "bogus"]) }
    assert_equal 1, status
    assert_match(/--status must be one of/, out)
  end

  def test_status_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_issues_status(["034", "extra", "--status", "dismissed"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  def test_status_fixed_requires_url
    out, status = capture_stderr_and_exit { cmd_issues_status(["034", "--status", "fixed"]) }
    assert_equal 1, status
    assert_match(/marking fixed requires --url/, out)
  end

  # A document fix (Google Doc, process change) carries no app/baseline — it must
  # not be forced to invent one. Run with no playbook session so the command stops
  # at the credential guard: arg validation is proven to pass without this test
  # ever reaching the network.
  def test_status_fixed_with_url_alone_passes_arg_validation
    out, status = without_playbook_session do
      capture_stderr_and_exit { cmd_issues_status(["034", "--status", "fixed", "--url", "https://docs.google.com/d/1"]) }
    end
    refute_match(/marking fixed requires/, out)
    refute_match(/--baseline-version requires --app/, out)
    assert_equal 1, status
    assert_match(/dev auth login --app playbook/, out)
  end

  def test_status_app_without_baseline_version_is_rejected
    out, status = capture_stderr_and_exit do
      cmd_issues_status(["034", "--status", "fixed", "--url", "https://pr/1", "--app", "playbook-app"])
    end
    assert_equal 1, status
    assert_match(/--app requires --baseline-version/, out)
  end

  def test_status_baseline_version_without_app_is_rejected
    out, status = capture_stderr_and_exit do
      cmd_issues_status(["034", "--status", "fixed", "--url", "https://pr/1", "--baseline-version", "0.1.4"])
    end
    assert_equal 1, status
    assert_match(/--baseline-version requires --app/, out)
  end

  def test_status_rejects_unknown_app
    out, status = capture_stderr_and_exit do
      cmd_issues_status(["034", "--status", "fixed", "--url", "https://pr/1", "--app", "not-an-app", "--baseline-version", "0.1.4"])
    end
    assert_equal 1, status
    assert_match(/Unknown --app 'not-an-app'/, out)
  end

  # ---- issue_fix_deployment ----

  def test_fix_deployment_reads_the_latest_fix
    issue = graph_issue.merge("fixes" => [
      { "url" => "https://pr/1", "deployment" => { "app" => "platform", "baseline_version" => "0.0.1" } },
      { "url" => "https://pr/2", "deployment" => { "app" => "playbook-app", "baseline_version" => "0.1.4" } },
    ])
    assert_equal({ "app" => "playbook-app", "baseline_version" => "0.1.4" }, issue_fix_deployment(issue))
  end

  def test_fix_deployment_nil_for_document_fix_and_no_fixes
    assert_nil issue_fix_deployment(graph_issue.merge("fixes" => [{ "url" => "https://docs.google.com/d/1" }]))
    assert_nil issue_fix_deployment(graph_issue)
  end

  # ---- issue_released_since_fix? (deployed-detection logic) ----

  def test_released_since_fix_true_when_release_newer_than_fix
    info = { "version" => "0.1.5", "released_at" => "2026-07-10T12:00:00Z" }
    assert issue_released_since_fix?(info, fixed_issue)
  end

  def test_released_since_fix_false_when_release_predates_fix
    info = { "version" => "0.1.9", "released_at" => "2026-07-10T08:00:00Z" }
    refute issue_released_since_fix?(info, fixed_issue)
  end

  def test_released_since_fix_falls_back_to_tag_when_timestamp_missing
    # No released_at → compare the live tag to the latest fix's baseline.
    assert issue_released_since_fix?({ "version" => "0.1.5" }, fixed_issue)
    refute issue_released_since_fix?({ "version" => "0.1.4" }, fixed_issue)
  end

  def test_released_since_fix_false_for_document_fix_without_timestamps
    # No deployment → no baseline → nothing to detect; reconcile skips these.
    refute issue_released_since_fix?({ "version" => "0.1.5" }, fixed_issue(deployment: nil))
  end

  # ---- playbook tenant login wiring ----

  def test_issue_endpoint_is_playbook_on_platform_host
    ep = issue_endpoint(false)
    assert_equal "playbook", ep[:app]
    assert_equal "https://idempotent.io", ep[:active_url], "playbook rides the platform host"
    assert_equal "http://localhost:9300", issue_endpoint(true)[:active_url]
  end

  def test_issues_paths_are_tenant_scoped
    assert_equal "/playbook/issues", issues_path
    assert_equal "/playbook/issues/claims", issues_path("/claims")
    assert_equal "/playbook/issues/034/status", issues_path("/034/status")
  end

  def test_playbook_has_its_own_session_file
    cfg = ApiClient::SESSION_CONFIG.fetch("playbook")
    assert_match(%r{/\.platform/devops_playbook$}, cfg[:file])
    assert_equal "session_id", cfg[:header]
  end

  def test_playbook_is_not_a_deployable_endpoint
    # Must stay out of ENDPOINTS so `dev tasks`/`invariants`/`version` fanout
    # never hits playbook with platform-only paths.
    refute_includes ApiClient::ENDPOINTS.map { |e| e[:app] }, "playbook"
  end

  def test_playbook_is_an_opt_in_login_app
    assert_includes LOGIN_APPS, "playbook"
  end

  def test_login_rejects_unknown_app_and_lists_playbook
    out, status = capture_stderr_and_exit { cmd_auth_login(["--app", "bogus"]) }
    assert_equal 1, status
    assert_match(/--app must be one of:.*playbook/, out)
  end

  def test_require_playbook_session_names_exact_login_command
    out, status = without_playbook_session { capture_stderr_and_exit { require_playbook_session!(false) } }
    assert_equal 1, status
    assert_match(/dev auth login --app playbook/, out)
  end

  def test_require_playbook_session_localhost_names_localhost_login_command
    out, status = without_playbook_session { capture_stderr_and_exit { require_playbook_session!(true) } }
    assert_equal 1, status
    assert_match(/dev auth login --app playbook --localhost/, out)
  end

  def test_playbook_session_file_is_scoped_by_localhost
    prod = ApiClient.session_file("playbook", false)
    local = ApiClient.session_file("playbook", true)
    refute_equal prod, local
    assert_match(%r{/\.platform/devops_playbook$}, prod)
    assert_match(%r{/\.platform/devops_playbook_localhost$}, local)
  end

  # ---- dev issues create: categories ----

  # The hand-filing list is a SUBSET of the full category list: `create` offers
  # only the categories that make sense to type, while `claim` covers them all.
  def test_manual_categories_are_a_subset_of_all_categories
    assert_equal %w[feature bug improvement], ISSUE_MANUAL_CATEGORIES
    assert_empty(ISSUE_MANUAL_CATEGORIES - ISSUE_CATEGORIES)
  end

  def test_create_rejects_an_automated_category
    out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "graphs", "--title", "x"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: feature, bug, improvement/, out)
    assert_match(/dev issues claim/, out)
  end

  # `claim` now accepts every category, including the hand-filed ones and
  # `suggestion`. Prove each gets PAST arg validation (stopping at the credential
  # guard) rather than being rejected as an unknown category.
  def test_claim_accepts_every_category
    ISSUE_CATEGORIES.each do |category|
      out, status = without_playbook_session { capture_stderr_and_exit { cmd_issues_claim(["--category", category]) } }
      assert_equal 1, status
      refute_match(/--category must be one of/, out, "#{category}: rejected by claim")
      assert_match(/dev auth login --app playbook/, out, "#{category}: did not reach the credential guard")
    end
  end

  def test_create_rejects_an_invalid_severity
    out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "bug", "--severity", "urgent"]) }
    assert_equal 1, status
    assert_match(/--severity must be one of: low, medium, high/, out)
  end

  def test_create_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "bug", "extra"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  # ---- dev issues create: attachments (validated before any network call) ----

  def test_create_rejects_a_missing_image
    out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "bug", "--image", "/nope/missing.png"]) }
    assert_equal 1, status
    assert_match(%r{--image /nope/missing\.png: no such file}, out)
  end

  def test_create_rejects_an_unsupported_image_type
    Tempfile.create(["thing", ".xyz"]) do |f|
      out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "bug", "--image", f.path]) }
      assert_equal 1, status
      assert_match(/unsupported file type/, out)
    end
  end

  def test_issue_file_type_maps_known_extensions
    assert_equal "png", issue_file_type("/tmp/shot.PNG")
    assert_equal "jpg", issue_file_type("/tmp/shot.jpeg")
    assert_equal "jpg", issue_file_type("/tmp/shot.jpg")
    assert_equal "csv", issue_file_type("/tmp/rows.csv")
  end

  def test_issue_file_type_rejects_unsupported
    assert_nil issue_file_type("/tmp/thing.xyz")
    assert_nil issue_file_type("/tmp/noext")
  end

  def test_issue_data_url_is_base64_with_mime
    Tempfile.create(["shot", ".png"]) do |f|
      f.binmode
      f.write("hello")
      f.flush
      assert_equal "data:image/png;base64,#{Base64.strict_encode64('hello')}", issue_data_url(f.path)
    end
  end

  # ---- dev issues create: the $EDITOR buffer ----

  def test_editor_template_explains_that_no_title_is_needed
    t = issue_editor_template
    assert_match(/do NOT need a title/, t)
    assert_match(/--title/, t)
  end

  def test_parse_editor_brief_keeps_the_whole_buffer
    brief = parse_issue_editor_brief("Export button does nothing\n\nClicking it is a no-op.\n")
    assert_equal "Export button does nothing\n\nClicking it is a no-op.", brief
  end

  def test_parse_editor_brief_strips_comment_lines
    assert_equal "Body", parse_issue_editor_brief("# instructions\nBody\n# more\n")
  end

  def test_parse_editor_brief_empty_is_nil
    assert_nil parse_issue_editor_brief("")
    assert_nil parse_issue_editor_brief("# only comments\n\n   \n")
    assert_nil parse_issue_editor_brief(issue_editor_template)
  end

  # ---- dev issues create: url + attachment extraction from the brief ----

  def test_extract_source_url_lifts_a_url_only_line
    brief, url = issue_extract_source_url("https://admin.clubaid.co/admin/issues/013?x=1\nThe box is too short.\n")
    assert_equal "https://admin.clubaid.co/admin/issues/013?x=1", url
    assert_equal "The box is too short.", brief
  end

  def test_extract_source_url_leaves_an_inline_url_alone
    brief, url = issue_extract_source_url("broken link on https://clubaid.co/pricing\n")
    assert_nil url
    assert_equal "broken link on https://clubaid.co/pricing", brief
  end

  def test_extract_attachment_paths_pulls_an_escaped_path_jammed_onto_a_sentence
    # The exact shape ISS-071 was filed with: a Finder-style path with escaped
    # spaces, run straight onto the end of the sentence with no separator.
    Tempfile.create(["Screenshot 2026-07-26 at 12.25.33 PM", ".png"]) do |f|
      escaped = f.path.gsub(" ", "\\ ")
      brief, paths = issue_extract_attachment_paths("The comment box is not tall enough.#{escaped}")
      assert_equal [f.path], paths
      assert_equal "The comment box is not tall enough.", brief
    end
  end

  def test_extract_attachment_paths_handles_a_plain_path_on_its_own_line
    Tempfile.create(["shot", ".png"]) do |f|
      brief, paths = issue_extract_attachment_paths("Broken chart\n#{f.path}\n")
      assert_equal [f.path], paths
      assert_equal "Broken chart", brief
    end
  end

  def test_extract_attachment_paths_ignores_text_that_only_looks_like_a_path
    brief, paths = issue_extract_attachment_paths("the /admin/issues page is broken")
    assert_empty paths
    assert_equal "the /admin/issues page is broken", brief
  end

  def test_extract_attachment_paths_leaves_a_brief_with_no_paths_untouched
    brief, paths = issue_extract_attachment_paths("Just a description")
    assert_empty paths
    assert_equal "Just a description", brief
  end

  # ---- dev issues create/resume: the session id ----

  def test_session_comment_body_carries_the_uuid_and_the_resume_command
    body = issue_session_comment_body("abc-123")
    assert_match(/abc-123/, body)
    assert_match(/claude --resume abc-123/, body)
  end

  # A reopened issue accumulates one session comment per session; resume must
  # take the most recent, not the first.
  def test_session_uuid_from_comments_picks_the_latest
    comments = [
      { "body" => issue_session_comment_body("first-uuid") },
      { "body" => "unrelated chatter" },
      { "body" => issue_session_comment_body("second-uuid") },
    ]
    assert_equal "second-uuid", issue_session_uuid_from_comments(comments)
  end

  def test_session_uuid_from_comments_nil_when_absent
    assert_nil issue_session_uuid_from_comments([{ "body" => "no session here" }])
    assert_nil issue_session_uuid_from_comments([{ "transition" => { "from" => "open", "to" => "claimed" } }])
    assert_nil issue_session_uuid_from_comments([])
    assert_nil issue_session_uuid_from_comments(nil)
  end

  def test_resume_requires_an_issue_number
    out, status = capture_stderr_and_exit { cmd_issues_resume([]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
  end

  def test_resume_rejects_extra_arguments
    out, status = capture_stderr_and_exit { cmd_issues_resume(["041", "extra"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  # ---- dev issues create/resume: spawn argv ----

  def test_create_argv_pins_the_session_id
    argv = issue_create_claude_argv("read the plan at /p.md and implement it", "uuid-9")
    assert_equal "claude", argv.first
    assert_includes argv, "--dangerously-skip-permissions"
    assert_equal "uuid-9", argv[argv.index("--session-id") + 1]
    assert_equal "read the plan at /p.md and implement it", argv.last
  end

  def test_resume_argv_uses_the_session_id
    assert_equal ["claude", "--resume", "uuid-7"], issue_resume_claude_argv("uuid-7")
  end

  # ---- dev issues create: the generated plan ----

  # A hand-filed issue from `dev issues create`: manual category, no club.
  def manual_issue
    {
      "id" => "iss-41",
      "number" => "041",
      "category" => "bug",
      "status" => "claimed",
      "severity" => "medium",
      "title" => "Export button does nothing",
      "body" => "Clicking Export on the members page is a no-op.",
      "created" => { "at" => "2026-07-26T09:00:00Z", "by" => { "name" => "Mike Bryzek" } },
      "attachments" => [
        { "id" => "att-1", "file" => { "id" => "f-9", "name" => "a.png", "url" => "https://img/a.png" } },
      ],
      "occurrence_count" => 1,
    }
  end

  def test_manual_plan_lists_local_image_paths
    md = manual_issue_plan_markdown(
      issue: manual_issue,
      date: "2026-07-26",
      local_paths: ["/Users/mbryzek/shots/a.png"],
      body: "PROMPT BODY",
    )
    assert_match(/ISS-041/, md)
    assert_match(/Export button does nothing/, md)
    assert_match(%r{/Users/mbryzek/shots/a\.png}, md)
    assert_match(/PROMPT BODY/, md)
    # The plan must always tell the session how to close the issue, with its number.
    assert_match(/dev issues status 041 --status fixed/, md)
  end

  def test_manual_plan_omits_the_attachment_section_when_there_are_no_files
    md = manual_issue_plan_markdown(issue: manual_issue, date: "2026-07-26", local_paths: [], body: "BODY")
    refute_match(/Attached files/, md)
  end

  # The shared prompt body must exist on disk — write_manual_issue_plan reads it.
  def test_manual_body_file_exists
    assert File.file?(File.expand_path("../claude-issues/manual-body.md", __dir__))
  end

  # ---- registration ----

  def test_create_and_resume_are_registered_subcommands
    assert_includes SUBCOMMANDS["issues"], "create"
    assert_includes SUBCOMMANDS["issues"], "resume"
    assert INVOCATIONS.key?("issues create")
    assert INVOCATIONS.key?("issues resume")
    assert_match(/dev issues create/, usage_for("issues create"))
    assert_match(/dev issues resume/, usage_for("issues resume"))
  end
end
