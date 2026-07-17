#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev issue {claim,status,reconcile}`: the pure plan-rendering helpers (no
# network), the claim/status arg validation, and the clubaid credential guard.
# Network paths (claim/status HTTP) are not exercised here — they exit before any
# request when args or credentials are missing.
class TestDevIssue < Minitest::Test
  include DevTestSupport

  # Run a block as if `dev login --app clubaid` had never been run. Guards the
  # arg-validation tests: this box has a real clubaid session, so without it a
  # command that gets past validation would fire a live request at production.
  def without_clubaid_session
    orig = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:session_id_for) do |app, use_localhost:|
      app == "clubaid" ? nil : orig.call(app, use_localhost: use_localhost)
    end
    yield
  ensure
    ApiClient.define_singleton_method(:session_id_for, orig)
  end

  def graph_issue
    {
      "id" => "iss-1",
      "tenant" => { "id" => "clubaid" },
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
      "category" => "court_reserve",
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

  def fixed_issue(deployment: { "app" => "clubaid-app", "baseline_version" => "0.1.4" })
    graph_issue.merge(
      "status" => "fixed",
      "fixed_at" => "2026-07-10T09:00:00Z",
      "fixes" => [{ "url" => "https://github.com/mbryzek/clubaid-app/pull/1", "deployment" => deployment }.compact],
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
    assert_includes md, "`dev issue claim --category graphs`"
    assert_includes md, "## Issues to fix"
    assert_includes md, "### 1. ISS-034 — Bars overflow the axis"
    assert_includes md, "### 2. ISS-036 — Bars overflow the axis"
    assert_includes md, "BODY-ORIENTATION"
    assert_includes md, "## Closing each issue"
    assert_includes md, 'dev issue status <number> --status fixed --url "<PR URL>" --app <deployable-app> --baseline-version <live version>'
    assert_includes md, 'dev issue status <number> --status fixed --url "<doc URL>"'
    assert_includes md, "--status needs_input"
  end

  # ---- issue_summary_line ----

  def test_summary_line_shows_number_category_status_club_and_title
    assert_equal "  1. ISS-034 · graphs · claimed · Padel Haus · Bars overflow the axis",
                 issue_summary_line(graph_issue, 1)
  end

  def test_summary_line_omits_club_when_absent
    assert_equal "  2. ISS-035 · court_reserve · open · Members export empty for 3 clubs",
                 issue_summary_line(crawl_issue, 2)
  end

  def test_summary_line_truncates_long_title
    line = issue_summary_line(graph_issue.merge("title" => "x" * 200), 3)
    assert_includes line, "..."
    assert line.length < 120, "summary line should be truncated: #{line.length}"
  end

  def test_summary_line_prefixes_parent_club
    assert_includes issue_summary_line(child_club_issue, 4), "  4. ISS-036 · graphs · claimed · Bounce / Baltimore · "
  end

  # ---- per-category body files are real and reachable ----

  def test_every_category_has_a_body_file
    ISSUE_CATEGORIES.each do |category|
      body = issue_body_text(category)
      assert_includes body, "## How this pipeline works", "#{category}: missing pipeline map"
      assert_includes body, "## Working rules", "#{category}: missing working rules"
    end
  end

  def test_categories_match_the_spec_enum
    assert_equal %w[graphs court_reserve app admin platform infra], ISSUE_CATEGORIES
  end

  def test_graphs_body_orients_to_clubaid_app
    assert_includes issue_body_text("graphs"), "mbryzek/clubaid-app"
  end

  def test_court_reserve_body_orients_to_the_crawl_pipeline
    body = issue_body_text("court_reserve")
    assert_includes body, "mbryzek/workers"           # the browser scraper
    assert_includes body, "courtreserve"              # the platform ingest/parse package
    assert_includes body, "log review"                # where these issues come from
  end

  # ---- issues list path filters by `statuses` (plural), never `status` ----
  # Regression: the singular `status=open` is an unknown query parameter the
  # server ignores, so the claim preview and reconcile scan saw EVERY status
  # instead of just open/fixed. The spec parameter is the repeatable `statuses`.

  def test_issues_list_path_uses_plural_statuses_param
    path = issues_list_path(statuses: "open", category: "graphs")
    assert_includes path, "statuses=open"
    refute_includes path, "status=open"   # the singular, server-ignored form
    assert_includes path, "category=graphs"
    assert_includes path, "limit=100"
    assert_includes path, "offset=0"
  end

  def test_issues_list_path_omits_category_when_absent
    path = issues_list_path(statuses: "fixed")
    assert_includes path, "statuses=fixed"
    refute_includes path, "category="
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

  # ---- cmd_issue_claim arg validation (exits before any network) ----

  def test_claim_requires_category
    out, status = capture_stderr_and_exit { cmd_issue_claim([]) }
    assert_equal 1, status
    assert_match(/--category is required/, out)
    ISSUE_CATEGORIES.each { |c| assert_includes out, c, "error must list the valid categories" }
    assert_includes out, "  Usage: #{usage_for('issue claim')}"
  end

  def test_claim_requires_category_even_with_yes_and_no_spawn
    out, status = capture_stderr_and_exit { cmd_issue_claim(["--yes", "--no-spawn"]) }
    assert_equal 1, status
    assert_match(/--category is required/, out)
  end

  def test_claim_rejects_invalid_category
    out, status = capture_stderr_and_exit { cmd_issue_claim(["--category", "bogus"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: graphs, court_reserve, app, admin, platform, infra/, out)
  end

  def test_claim_rejects_category_without_value
    out, status = capture_stderr_and_exit { cmd_issue_claim(["--category"]) }
    assert_equal 1, status
    assert_match(/--category requires a value/, out)
  end

  def test_claim_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_issue_claim(["--category", "graphs", "extra"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  # ---- cmd_issue_status arg validation (exits before any network) ----

  def test_status_requires_number
    out, status = capture_stderr_and_exit { cmd_issue_status(["--status", "dismissed"]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
  end

  def test_status_requires_status
    out, status = capture_stderr_and_exit { cmd_issue_status(["034"]) }
    assert_equal 1, status
    assert_match(/--status is required/, out)
  end

  def test_status_rejects_invalid_status
    out, status = capture_stderr_and_exit { cmd_issue_status(["034", "--status", "bogus"]) }
    assert_equal 1, status
    assert_match(/--status must be one of/, out)
  end

  def test_status_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_issue_status(["034", "extra", "--status", "dismissed"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  def test_status_fixed_requires_url
    out, status = capture_stderr_and_exit { cmd_issue_status(["034", "--status", "fixed"]) }
    assert_equal 1, status
    assert_match(/marking fixed requires --url/, out)
  end

  # A document fix (Google Doc, process change) carries no app/baseline — it must
  # not be forced to invent one. Run with no clubaid session so the command stops
  # at the credential guard: arg validation is proven to pass without this test
  # ever reaching the network.
  def test_status_fixed_with_url_alone_passes_arg_validation
    out, status = without_clubaid_session do
      capture_stderr_and_exit { cmd_issue_status(["034", "--status", "fixed", "--url", "https://docs.google.com/d/1"]) }
    end
    refute_match(/marking fixed requires/, out)
    refute_match(/--baseline-version requires --app/, out)
    assert_equal 1, status
    assert_match(/dev login --app clubaid/, out)
  end

  def test_status_app_without_baseline_version_is_rejected
    out, status = capture_stderr_and_exit do
      cmd_issue_status(["034", "--status", "fixed", "--url", "https://pr/1", "--app", "clubaid-app"])
    end
    assert_equal 1, status
    assert_match(/--app requires --baseline-version/, out)
  end

  def test_status_baseline_version_without_app_is_rejected
    out, status = capture_stderr_and_exit do
      cmd_issue_status(["034", "--status", "fixed", "--url", "https://pr/1", "--baseline-version", "0.1.4"])
    end
    assert_equal 1, status
    assert_match(/--baseline-version requires --app/, out)
  end

  def test_status_rejects_unknown_app
    out, status = capture_stderr_and_exit do
      cmd_issue_status(["034", "--status", "fixed", "--url", "https://pr/1", "--app", "not-an-app", "--baseline-version", "0.1.4"])
    end
    assert_equal 1, status
    assert_match(/Unknown --app 'not-an-app'/, out)
  end

  # ---- issue_fix_deployment ----

  def test_fix_deployment_reads_the_latest_fix
    issue = graph_issue.merge("fixes" => [
      { "url" => "https://pr/1", "deployment" => { "app" => "platform", "baseline_version" => "0.0.1" } },
      { "url" => "https://pr/2", "deployment" => { "app" => "clubaid-app", "baseline_version" => "0.1.4" } },
    ])
    assert_equal({ "app" => "clubaid-app", "baseline_version" => "0.1.4" }, issue_fix_deployment(issue))
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

  # ---- clubaid tenant login wiring ----

  def test_issue_endpoint_is_clubaid_on_platform_host
    ep = issue_endpoint(false)
    assert_equal "clubaid", ep[:app]
    assert_equal "https://idempotent.io", ep[:active_url], "clubaid rides the platform host"
    assert_equal "http://localhost:9300", issue_endpoint(true)[:active_url]
  end

  def test_issues_paths_are_tenant_scoped
    assert_equal "/clubaid/issues", issues_path
    assert_equal "/clubaid/issues/claims", issues_path("/claims")
    assert_equal "/clubaid/issues/034/status", issues_path("/034/status")
  end

  def test_clubaid_has_its_own_session_file
    cfg = ApiClient::SESSION_CONFIG.fetch("clubaid")
    assert_match(%r{/\.platform/devops_clubaid$}, cfg[:file])
    assert_equal "session_id", cfg[:header]
  end

  def test_clubaid_is_not_a_deployable_endpoint
    # Must stay out of ENDPOINTS so `dev tasks`/`invariants`/`version` fanout
    # never hits clubaid with platform-only paths.
    refute_includes ApiClient::ENDPOINTS.map { |e| e[:app] }, "clubaid"
  end

  def test_clubaid_is_an_opt_in_login_app
    assert_includes LOGIN_APPS, "clubaid"
  end

  def test_login_rejects_unknown_app_and_lists_clubaid
    out, status = capture_stderr_and_exit { cmd_login(["--app", "bogus"]) }
    assert_equal 1, status
    assert_match(/--app must be one of:.*clubaid/, out)
  end

  def test_require_clubaid_session_names_exact_login_command
    out, status = without_clubaid_session { capture_stderr_and_exit { require_clubaid_session!(false) } }
    assert_equal 1, status
    assert_match(/dev login --app clubaid/, out)
  end

  def test_require_clubaid_session_localhost_names_localhost_login_command
    out, status = without_clubaid_session { capture_stderr_and_exit { require_clubaid_session!(true) } }
    assert_equal 1, status
    assert_match(/dev login --app clubaid --localhost/, out)
  end

  def test_clubaid_session_file_is_scoped_by_localhost
    prod = ApiClient.session_file("clubaid", false)
    local = ApiClient.session_file("clubaid", true)
    refute_equal prod, local
    assert_match(%r{/\.platform/devops_clubaid$}, prod)
    assert_match(%r{/\.platform/devops_clubaid_localhost$}, local)
  end
end
