#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev feedback {claim,status}`: the pure plan-rendering helpers (no
# network), the status-command arg validation, and the clubaid credential guard.
# Network paths (claim/status HTTP) are not exercised here — they exit before any
# request when args or credentials are missing.
class TestDevFeedback < Minitest::Test
  include DevTestSupport

  def chart_comment
    {
      "id" => "cmt-1",
      "club" => { "id" => "club-9", "name" => "Padel Haus" },
      "page_url" => "/graphs/financial?range=ytd",
      "chart_key" => "revenue-by-type",
      "viewport" => "1440x900",
      "created_at" => "2026-07-10T12:00:00Z",
      "screenshot" => { "url" => "https://img/shot.png" },
      "comment" => "Bars overflow the axis",
    }
  end

  def page_comment
    {
      "id" => "cmt-2",
      "club" => { "id" => "club-9", "name" => "Padel Haus" },
      "page_url" => "/graphs/member",
      "chart_key" => nil,
      "viewport" => nil,
      "created_at" => "2026-07-09T08:30:00Z",
      "screenshot" => nil,
      "comment" => "Whole page loads slowly",
    }
  end

  # Child club (bare name "Baltimore") with a parent — ambiguous without it.
  def child_comment
    chart_comment.merge(
      "id" => "cmt-3",
      "club" => { "id" => "bounce-baltimore", "name" => "Baltimore", "parent" => { "id" => "bounce", "name" => "Bounce" } },
    )
  end

  # ---- feedback_render_item ----

  def test_render_item_with_chart_and_screenshot
    out = feedback_render_item(chart_comment, 1)
    assert_includes out, "### 1. Padel Haus — revenue-by-type"
    assert_includes out, "- Comment id: `cmt-1`"
    assert_includes out, "- Chart: `revenue-by-type`"
    assert_includes out, "- Screenshot: https://img/shot.png"
    assert_includes out, "> Bars overflow the axis"
  end

  def test_render_item_page_level_and_missing_optionals
    out = feedback_render_item(page_comment, 2)
    assert_includes out, "### 2. Padel Haus — page-level"
    assert_includes out, "- Scope: page-level feedback (no single chart)"
    assert_includes out, "- Viewport: unknown"
    assert_includes out, "- Screenshot: none captured"
    refute_includes out, "- Chart:"
  end

  def test_render_item_quotes_multiline_comment
    c = chart_comment.merge("comment" => "line one\nline two")
    out = feedback_render_item(c, 1)
    assert_includes out, "> line one\n> line two"
  end

  def test_render_item_prefixes_parent_club
    out = feedback_render_item(child_comment, 1)
    assert_includes out, "### 1. Bounce / Baltimore — revenue-by-type"
    assert_includes out, "- Club: Bounce / Baltimore (`bounce-baltimore`)"
  end

  # ---- feedback_club_label ----

  def test_club_label_prefixes_parent_when_present
    assert_equal "Bounce / Baltimore", feedback_club_label(child_comment)
  end

  def test_club_label_bare_name_without_parent
    assert_equal "Padel Haus", feedback_club_label(chart_comment)
  end

  def test_club_label_falls_back_to_id_then_placeholder
    assert_equal "club-x", feedback_club_label("club" => { "id" => "club-x" })
    assert_equal "?", feedback_club_label({})
  end

  # ---- feedback_plan_markdown ----

  def test_plan_markdown_structure
    md = feedback_plan_markdown(items: [chart_comment, page_comment], date: "2026-07-10", body: "BODY-ORIENTATION")
    assert_includes md, "# Graph feedback — 2 item(s) claimed 2026-07-10"
    assert_includes md, "## Items to fix"
    assert_includes md, "### 1. Padel Haus — revenue-by-type"
    assert_includes md, "### 2. Padel Haus — page-level"
    assert_includes md, "BODY-ORIENTATION"
    assert_includes md, "## Closing each item"
    assert_includes md, 'dev feedback status <id> --status fixed --note "<PR URL>"'
    assert_includes md, "--status needs_input"
  end

  # ---- feedback_summary_line ----

  def test_summary_line_truncates_long_comment
    c = chart_comment.merge("comment" => "x" * 200)
    line = feedback_summary_line(c, 3)
    assert_includes line, "  3. Padel Haus · 2026-07-10 · revenue-by-type — "
    assert_includes line, "..."
    assert line.length < 120, "summary line should be truncated: #{line.length}"
  end

  def test_summary_line_page_level_label
    assert_includes feedback_summary_line(page_comment, 1), "page-level"
  end

  def test_summary_line_prefixes_parent_club
    assert_includes feedback_summary_line(child_comment, 4), "  4. Bounce / Baltimore · 2026-07-10 · revenue-by-type — "
  end

  # ---- shared body file is real and reachable ----

  def test_feedback_body_text_reads_shared_file
    body = feedback_body_text
    assert_includes body, "## How this pipeline works"
    assert_includes body, "## Working rules"
    assert_includes body, "mbryzek/clubaid-app"
  end

  # ---- cmd_feedback_status arg validation (exits before any network) ----

  def test_status_requires_id
    out, status = capture_stderr_and_exit { cmd_feedback_status(["--status", "fixed"]) }
    assert_equal 1, status
    assert_match(/missing comment id/, out)
  end

  def test_status_requires_status
    out, status = capture_stderr_and_exit { cmd_feedback_status(["cmt-1"]) }
    assert_equal 1, status
    assert_match(/--status is required/, out)
  end

  def test_status_rejects_invalid_status
    out, status = capture_stderr_and_exit { cmd_feedback_status(["cmt-1", "--status", "bogus"]) }
    assert_equal 1, status
    assert_match(/--status must be one of/, out)
  end

  def test_status_rejects_unexpected_positional
    out, status = capture_stderr_and_exit { cmd_feedback_status(["cmt-1", "extra", "--status", "fixed"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  # ---- clubaid tenant login wiring ----

  def test_feedback_endpoint_is_clubaid_on_platform_host
    ep = feedback_endpoint(false)
    assert_equal "clubaid", ep[:app]
    assert_equal "https://idempotent.io", ep[:active_url], "clubaid rides the platform host"
    assert_equal "http://localhost:9300", feedback_endpoint(true)[:active_url]
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
    orig = ApiClient.method(:session_id_for)
    ApiClient.define_singleton_method(:session_id_for) { |app| app == "clubaid" ? nil : orig.call(app) }
    out, status = capture_stderr_and_exit { require_clubaid_session! }
    assert_equal 1, status
    assert_match(/dev login --app clubaid/, out)
  ensure
    ApiClient.define_singleton_method(:session_id_for, orig)
  end
end
