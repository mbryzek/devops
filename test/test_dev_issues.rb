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

  # Run a block as if `dev login --app playbook` had never been run. Guards the
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

  def test_summary_line_shows_number_category_status_club_and_title
    assert_equal "  1. ISS-034 · graphs · claimed · Padel Haus · Bars overflow the axis",
                 issue_summary_line(graph_issue, 1)
  end

  def test_summary_line_omits_club_when_absent
    assert_equal "  2. ISS-035 · worker · open · Members export empty for 3 clubs",
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
    assert_equal %w[graphs worker insights], ISSUE_CATEGORIES
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

  # ---- issue_categories_present: enum-ordered, known categories only ----

  def test_categories_present_returns_enum_order_known_only
    open = [crawl_issue.merge("category" => "insights"), graph_issue.merge("status" => "open"), crawl_issue]
    # graphs (from graph_issue) + worker (crawl_issue) + insights, listed in enum order.
    assert_equal %w[graphs worker insights], issue_categories_present(open)
  end

  def test_categories_present_empty_when_no_known_open
    assert_empty issue_categories_present([crawl_issue.merge("category" => "mystery")])
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
    assert_match(/dev login --app playbook/, out)
  end

  def test_claim_rejects_invalid_category
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--category", "bogus"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: graphs, worker, insights/, out)
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
    assert_match(/dev login --app playbook/, out)
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
    out, status = capture_stderr_and_exit { cmd_login(["--app", "bogus"]) }
    assert_equal 1, status
    assert_match(/--app must be one of:.*playbook/, out)
  end

  def test_require_playbook_session_names_exact_login_command
    out, status = without_playbook_session { capture_stderr_and_exit { require_playbook_session!(false) } }
    assert_equal 1, status
    assert_match(/dev login --app playbook/, out)
  end

  def test_require_playbook_session_localhost_names_localhost_login_command
    out, status = without_playbook_session { capture_stderr_and_exit { require_playbook_session!(true) } }
    assert_equal 1, status
    assert_match(/dev login --app playbook --localhost/, out)
  end

  def test_playbook_session_file_is_scoped_by_localhost
    prod = ApiClient.session_file("playbook", false)
    local = ApiClient.session_file("playbook", true)
    refute_equal prod, local
    assert_match(%r{/\.platform/devops_playbook$}, prod)
    assert_match(%r{/\.platform/devops_playbook_localhost$}, local)
  end

  # ---- dev issues create: categories ----

  # The batch-claim routing list and the manually-filed list must stay disjoint,
  # or `dev issues claim` would sweep hand-filed work into an automated plan.
  def test_manual_categories_are_disjoint_from_batch_claim_categories
    assert_equal %w[graphs worker insights], ISSUE_CATEGORIES
    assert_equal %w[feature bug improvement], ISSUE_MANUAL_CATEGORIES
    assert_empty(ISSUE_CATEGORIES & ISSUE_MANUAL_CATEGORIES)
  end

  def test_create_rejects_an_automated_category
    out, status = capture_stderr_and_exit { cmd_issues_create(["--category", "graphs", "--title", "x"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: feature, bug, improvement/, out)
    assert_match(/dev issues claim/, out)
  end

  def test_claim_still_rejects_a_manual_category
    out, status = capture_stderr_and_exit { cmd_issues_claim(["--category", "feature"]) }
    assert_equal 1, status
    assert_match(/--category must be one of: graphs, worker, insights/, out)
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

  def test_editor_template_prefills_the_title_and_explains_the_format
    t = issue_editor_template(title: "Bars overflow")
    assert_equal "Bars overflow", t.lines.first.chomp
    assert_match(/^# First line above is the issue TITLE/, t)
  end

  def test_parse_editor_text_splits_title_and_body
    parsed = parse_issue_editor_text("Bars overflow\n\nRevenue renders past the plot area.\nSecond line.\n")
    assert_equal "Bars overflow", parsed[:title]
    assert_equal "Revenue renders past the plot area.\nSecond line.", parsed[:body]
  end

  def test_parse_editor_text_strips_comment_lines
    parsed = parse_issue_editor_text("Title here\n# instructions\n#\n# more\n\nBody\n")
    assert_equal "Title here", parsed[:title]
    assert_equal "Body", parsed[:body]
  end

  def test_parse_editor_text_title_only_has_no_body
    parsed = parse_issue_editor_text("Just a title\n# instructions\n")
    assert_equal "Just a title", parsed[:title]
    assert_nil parsed[:body]
  end

  def test_parse_editor_text_empty_is_nil
    assert_nil parse_issue_editor_text("")
    assert_nil parse_issue_editor_text("# only comments\n\n   \n")
    assert_nil parse_issue_editor_text(issue_editor_template(title: nil))
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
