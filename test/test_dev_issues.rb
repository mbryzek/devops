#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev issues {claim,status,reconcile}`: the pure plan-rendering helpers (no
# network), the claim/status arg validation, and the playbook credential guard.
# Network paths (claim/status HTTP) are not exercised here — they exit before any
# request when args or credentials are missing. `DevTestSupport::NetworkGuard`
# (test_helper.rb) reads every credential as absent and raises on any request, so
# these commands stop at their credential guard and cannot reach production.
class TestDevIssues < Minitest::Test
  include DevTestSupport

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

  def comment(body: nil, transition: nil, visibility: "internal", at: "2026-07-11T09:00:00Z")
    {
      "id" => "cmt-#{at}",
      "created" => { "at" => at, "by" => { "name" => "Mike Bryzek" } },
      "visibility" => visibility,
      "body" => body,
      "transition" => transition,
    }.compact
  end

  # A timeline that closed the issue and then re-opened it: the shape every
  # re-opened issue has, and the one the plan must lead with.
  def reopen_comments
    [
      comment(body: "shipped the axis clamp", transition: { "from" => "claimed", "to" => "fixed" }),
      comment(body: "still broken on mobile", transition: { "from" => "fixed", "to" => "open" }, at: "2026-07-12T09:00:00Z"),
    ]
  end

  # ---- issue_label ----

  def test_issue_label_is_iss_prefixed_number
    assert_equal "ISS-034", issue_label(graph_issue)
  end

  # ---- issue_url / issue_link ----

  def test_issue_url_points_at_the_admin_console
    assert_equal "https://admin.clubaid.co/admin/issues/034", issue_url(graph_issue)
  end

  # capture_io redirects $stdout to a StringIO, which is not a tty — the same as
  # a release log or a pipe. The label must come through with no escape bytes.
  def test_issue_link_is_plain_text_when_stdout_is_not_a_terminal
    link = nil
    capture_io { link = issue_link(graph_issue) }
    assert_equal "ISS-034", link
  end

  def test_hyperlink_wraps_the_text_in_osc8_on_a_terminal
    # Util.hyperlink is what makes the label clickable; drive it directly rather
    # than faking a tty, since $stdout.tty? is the only thing issue_link adds.
    out = with_tty_stdout { Util.hyperlink("ISS-034", "https://example.com/x") }
    assert_equal "\e]8;;https://example.com/x\e\\ISS-034\e]8;;\e\\", out
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

  # `dev issues show` renders one issue, so there is nothing to number it against.
  def test_render_item_without_an_index_drops_the_number_prefix
    assert_includes issue_render_item(graph_issue), "### ISS-034 — Bars overflow the axis"
    refute_includes issue_render_item(graph_issue), "### 1."
  end

  def test_render_item_lists_previous_fix_prs
    out = issue_render_item(fixed_issue, 1)
    assert_includes out, "- Previous fixes: https://github.com/mbryzek/playbook-app/pull/1 (playbook-app 0.1.4)"
  end

  def test_render_item_omits_previous_fixes_when_none_recorded
    refute_includes issue_render_item(graph_issue, 1), "- Previous fixes:"
  end

  # ---- comment history + re-open ----

  def test_reopened_when_a_transition_returns_the_issue_to_open
    assert issue_reopened?(reopen_comments)
    refute issue_reopened?([]), "a freshly filed issue has no history"
    refute issue_reopened?([comment(body: "just a note")]), "a plain note is not a re-open"
  end

  def test_a_first_transition_to_open_is_not_a_reopen
    refute issue_reopened?([comment(transition: { "from" => "open", "to" => "open" })])
  end

  def test_render_item_leads_with_the_reopen_callout
    out = issue_render_item(fixed_issue, 1, comments: reopen_comments)
    banner = out.index("RE-OPENED")
    assert banner, "expected the re-open banner"
    assert banner < out.index("- Issue: `ISS-034`"), "banner must precede the issue fields"
    assert_includes out, "**RE-OPENED — the earlier attempt did not hold.**"
    assert_includes out, "Reason given: still broken on mobile"
    assert_includes out, "NEW `~/code/ai/<short-name>` directory on a NEW branch"
    assert_includes out, "never reuse"
  end

  def test_reopen_callout_counts_repeat_reopens
    twice = reopen_comments + [comment(transition: { "from" => "fixed", "to" => "open" }, at: "2026-07-14T09:00:00Z")]
    assert_includes issue_render_item(fixed_issue, 1, comments: twice), "**RE-OPENED 2 times — the earlier attempt did not hold.**"
  end

  # A suggestion session is told not to branch at all, so the callout must not
  # hand it a contradictory "on a NEW branch".
  def test_reopen_callout_omits_the_branch_for_an_investigate_only_category
    out = issue_render_item(graph_issue.merge("category" => "suggestion"), 1, comments: reopen_comments)
    assert_includes out, "NEW `~/code/ai/<short-name>` directory — never reuse the directory"
    refute_includes out, "on a NEW branch"
  end

  def test_render_item_has_no_callout_without_a_reopen
    refute_includes issue_render_item(graph_issue, 1, comments: [comment(body: "just a note")]), "RE-OPENED"
  end

  def test_render_item_includes_the_comment_history_oldest_first
    out = issue_render_item(fixed_issue, 1, comments: reopen_comments)
    assert_includes out, "**Comment history (2, oldest first):**"
    assert_includes out, "- 2026-07-11T09:00:00Z · Mike Bryzek · status claimed → fixed"
    assert_includes out, "  > shipped the axis clamp"
    assert_includes out, "- 2026-07-12T09:00:00Z · Mike Bryzek · status fixed → open"
    assert out.index("status claimed → fixed") < out.index("status fixed → open"), "oldest first"
  end

  def test_history_indents_multiline_comment_bodies
    out = issue_render_item(graph_issue, 1, comments: [comment(body: "line one\nline two")])
    assert_includes out, "  > line one\n  > line two"
  end

  def test_history_flags_a_comment_shared_with_the_submitter
    out = issue_render_item(graph_issue, 1, comments: [comment(body: "we are on it", visibility: "shared")])
    assert_includes out, "shared with the submitter"
    refute_includes issue_render_item(graph_issue, 1, comments: [comment(body: "internal")]), "shared with the submitter"
  end

  # Pointing a re-opened issue at the earlier session invites resuming it — the
  # opposite of the "new directory, new branch" instruction in the callout.
  def test_history_drops_the_session_bookkeeping_comment
    out = issue_render_item(graph_issue, 1, comments: [comment(body: "Claude session `abc-123` — resume with `claude --resume abc-123`")])
    refute_includes out, "Comment history"
    refute_includes out, "abc-123"
  end

  def test_history_keeps_a_session_comment_that_also_recorded_a_transition
    out = issue_render_item(graph_issue, 1,
                            comments: [comment(body: "Claude session `abc-123`", transition: { "from" => "open", "to" => "claimed" })])
    assert_includes out, "status open → claimed"
  end

  def test_render_item_without_comments_is_unchanged
    assert_equal issue_render_item(graph_issue, 1), issue_render_item(graph_issue, 1, comments: [])
  end

  def test_plan_markdown_renders_history_for_the_matching_issue_only
    md = issue_plan_markdown(items: [fixed_issue, child_club_issue], date: "2026-07-10", category: "graphs",
                             body: "BODY", comments_by_number: { "034" => reopen_comments })
    assert_includes md, "RE-OPENED"
    assert_includes md, "still broken on mobile"
    assert_equal 1, md.scan("Comment history").length, "ISS-036 has no history to render"
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
    assert_includes md, "Implement the fixes, open PRs"
  end

  # The plan WRAPPER (not just the body file) has to match the category. A
  # `suggestion` is swept into a claim like everything else since
  # ISSUE_NO_AUTO_CLAIM_CATEGORIES was removed, so if the wrapper still said
  # "implement the fixes, open PRs" the session would be told to build the very
  # thing suggestion-body.md forbids it from building.
  def suggestion_plan_markdown
    issue_plan_markdown(
      items: [graph_issue.merge("category" => "suggestion")],
      date: "2026-07-27",
      category: "suggestion",
      body: "BODY-ORIENTATION",
    )
  end

  def test_suggestion_plan_wrapper_never_says_implement_or_open_a_pr
    md = suggestion_plan_markdown
    refute_includes md, "Implement the fixes, open PRs"
    refute_includes md, "## Issues to fix"
    refute_includes md, "--status fixed"
    assert_includes md, "## Issues to investigate"
    assert_includes md, "do not create a branch, do not write code, do not open a"
  end

  def test_suggestion_plan_offers_needs_review_as_the_closing_move
    md = suggestion_plan_markdown
    assert_includes md, '`dev issues status <number> --status needs_review --comment "<your findings>"`'
    assert_includes md, "--status needs_input"
  end

  # `needs_review` is the suggestion-only door: every other category still closes
  # on fixed/needs_input exactly as before.
  def test_other_categories_keep_the_implementation_wrapper_unchanged
    (ISSUE_CATEGORIES - %w[suggestion]).each do |category|
      md = issue_plan_markdown(items: [graph_issue], date: "2026-07-27", category: category, body: "BODY")
      assert_includes md, "Implement the fixes, open PRs", "#{category}: lost the implementation framing"
      assert_includes md, "## Issues to fix", "#{category}: lost the fix heading"
      refute_includes md, "--status needs_review", "#{category}: should not offer needs_review"
    end
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
    (ISSUE_CATEGORIES - PIPELINE_CATEGORIES - %w[suggestion]).each do |category|
      assert_equal issue_default_body_text, issue_body_text(category), "#{category}: expected default body"
    end
  end

  # `suggestion` is the one category with its own body that is NOT a pipeline body:
  # it replaces default-body.md outright (an investigation, not a fix session), so
  # it must not equal the default body the way the other non-pipeline categories do.
  def test_suggestion_has_its_own_investigation_body
    body = issue_body_text("suggestion")
    refute_equal issue_default_body_text, body
    assert_includes body, "INVESTIGATE"
    assert_includes body, "Do not create a branch"
    assert_includes body, "needs_review"
  end

  # Regression: the body told every investigation session to close with
  # `dev issues status --number <NNN> ...`, but the number is POSITIONAL — the
  # parser has no `--number`, so it fell through to `leftover` and the command
  # exited "unexpected argument(s)", leaving the suggestion stuck in `claimed`.
  def test_suggestion_body_closing_command_matches_the_real_argument_parsing
    body = issue_body_text("suggestion")
    refute_includes body, "--number"
    assert_includes body, 'dev issues status <NNN> --status needs_review --comment "<your findings>"'
  end

  # The same guard for every body file: no plan may hand out a flag the parser
  # does not implement.
  def test_no_body_file_invents_a_number_flag
    ISSUE_CATEGORIES.each do |category|
      refute_includes issue_body_text(category), "--number", "#{category}: invents a --number flag"
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

  # A session that never learns the command cannot read the history the CLI now
  # exposes. suggestion-body.md is the trap: it REPLACES default-body.md rather
  # than layering on it, so a pointer added only to the default silently misses
  # every investigation session. Assert on both bodies a session can be handed.
  def test_every_standalone_body_points_at_dev_issues_show
    [issue_default_body_text, issue_body_text("suggestion")].each do |body|
      assert_includes body, "dev issues show"
    end
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
    assert_equal "read the plan at /p/x.md and implement it", issue_session_prompt("graphs", "/p/x.md")
  end

  # Regression: the single-plan prompt used to say "implement it" for EVERY
  # category, including `suggestion` — whose plan is investigate-only. A claim of
  # one category is the common case (`dev issues claim --category suggestion`), so
  # the contradiction landed on exactly the path the fan-out prompt already fixed.
  def test_issue_session_prompt_briefs_a_suggestion_plan_investigate_only
    prompt = issue_session_prompt("suggestion", "/p/s.md")
    assert_includes prompt, "/p/s.md"
    assert_includes prompt, "INVESTIGATE ONLY"
    assert_includes prompt, "--status needs_review"
    refute_includes prompt, "implement it"
  end

  def test_issue_claude_command_is_ccd_pinned_to_opus_1m
    cmd = issue_claude_command("graphs", "/p/x.md")
    assert_equal "claude", cmd[0]
    assert_includes cmd, "--dangerously-skip-permissions"          # the `ccd` alias
    assert_equal "claude-opus-5[1m]", cmd[cmd.index("--model") + 1]
    assert_equal issue_session_prompt("graphs", "/p/x.md"), cmd.last # prompt is the final arg
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
    prompt = issue_prompt_with_tab_title([graph_issue], issue_session_prompt("graphs", "/p/x.md"))
    assert_includes prompt, 'tab title to "ISS-034: Bars overflow the axis"'
    assert prompt.end_with?(issue_session_prompt("graphs", "/p/x.md")), prompt
  end

  def test_prompt_with_tab_title_is_untouched_without_issues
    assert_equal issue_session_prompt("graphs", "/p/x.md"),
                 issue_prompt_with_tab_title([], issue_session_prompt("graphs", "/p/x.md"))
  end

  # ---- claim prompt: one plan works directly, several fan out subagents ----

  def test_claim_prompt_single_plan_is_the_direct_prompt_for_its_category
    assert_equal issue_session_prompt("graphs", "/p/g.md"), issue_claim_prompt([["graphs", "/p/g.md"]])
    assert_equal issue_session_prompt("suggestion", "/p/s.md"), issue_claim_prompt([["suggestion", "/p/s.md"]])
  end

  def test_claim_prompt_multi_plan_dispatches_one_subagent_per_plan
    prompt = issue_claim_prompt([["graphs", "/p/g.md"], ["worker", "/p/w.md"]])
    assert_includes prompt, "2 issue plans"
    assert_includes prompt, "ONE subagent per plan"
    assert_includes prompt, "do NOT work the plans yourself"
    assert_includes prompt, "- graphs: /p/g.md"
    assert_includes prompt, "- worker: /p/w.md"
  end

  # Regression: the fan-out prompt used to tell EVERY subagent to "implement the
  # fixes, open PRs" — including the one handed a `suggestion` plan, whose whole
  # point is that it never builds anything. The plan is the authority now, and a
  # suggestion plan is labelled so the parent session cannot mis-brief it.
  def test_claim_prompt_multi_plan_marks_a_suggestion_plan_investigate_only
    prompt = issue_claim_prompt([["suggestion", "/p/s.md"], ["worker", "/p/w.md"]])
    assert_includes prompt, "- suggestion: /p/s.md (INVESTIGATE ONLY — no branch, no code, no PR)"
    refute_match(/- worker: \S+ \(INVESTIGATE/, prompt)
    assert_includes prompt, "--status needs_review"
  end

  def test_claim_argv_wraps_any_prompt_as_ccd_opus
    argv = interactive_claude_argv("do the thing")
    assert_equal "claude", argv[0]
    assert_includes argv, "--dangerously-skip-permissions"
    assert_equal "claude-opus-5[1m]", argv[argv.index("--model") + 1]
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

  # ---- cmd_issues_show arg validation (exits before any network) ----

  def test_show_requires_an_issue_number
    out, status = capture_stderr_and_exit { cmd_issues_show([]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
    assert_match(/dev issues show/, out)
  end

  def test_show_rejects_extra_positionals
    out, status = capture_stderr_and_exit { cmd_issues_show(%w[084 085]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): 085/, out)
  end

  def test_show_is_a_registered_subcommand_with_usage
    assert_includes SUBCOMMANDS["issues"], "show"
    assert INVOCATIONS.key?("issues show")
    assert_match(/dev issues show/, usage_for("issues show"))
  end

  # ---- cmd_issues_claim arg validation (exits before any network) ----

  # No --category is now valid (claim across all categories). Prove it gets PAST
  # arg validation by letting it run to the credential guard, which the network
  # guard leaves unsatisfied — so it stops there rather than claiming for real.
  def test_claim_without_category_passes_arg_validation
    out, status = capture_stderr_and_exit { cmd_issues_claim([]) }
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

  # ---- suggestion is swept like every other category ----

  def suggestion_queue
    open_queue + [graph_issue.merge("number" => "081", "category" => "suggestion", "status" => "open")]
  end

  def ordered_suggestion_queue
    issue_ordered_open(suggestion_queue, issue_categories_present(suggestion_queue))
  end

  # Regression: `suggestion` used to be excluded from a blanket claim (`all`/--yes).
  # It is swept like every other category now — what makes it different is its body
  # file (suggestion-body.md, which turns the session into an investigation), not
  # whether the sweep claims it.
  def test_prompt_all_takes_everything_including_suggestions
    ordered = ordered_suggestion_queue
    orig = Ask.method(:for_string)
    Ask.define_singleton_method(:for_string) { |_msg, _opts = {}| "all" }
    # Enum order: worker (078), suggestion (081), feature (079), improvement (080).
    assert_equal %w[078 081 079 080], issue_ask_selection(ordered, ordered).map { |c| c["number"] }
  ensure
    Ask.define_singleton_method(:for_string, orig)
  end

  def test_suggestions_are_still_selectable_by_number
    resolved, unknown = issue_resolve_requested("081", ordered_suggestion_queue)
    assert_equal %w[081], resolved.map { |c| c["number"] }
    assert_empty unknown
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

  # A whole-category suggestion pick now claims by category, exactly like any other
  # category selected in full — there is no more number-only exception for it.
  def test_claim_scope_is_by_category_for_a_whole_suggestion_category_too
    suggestions = suggestion_queue.select { |c| c["category"] == "suggestion" }
    assert_equal({ category: "suggestion" }, issue_claim_scope("suggestion", suggestions, suggestions))
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
    out, status = capture_stderr_and_exit { cmd_issues_snooze(["034", "--days", "1", "--comment", "confirm the migration"]) }
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

  # Proof of what the corrected suggestion-body.md closing command avoids: the
  # issue number has no flag form, so `--number 081` is swallowed as two stray
  # positionals and the command dies before it ever reaches the API.
  def test_status_rejects_a_number_flag_because_the_number_is_positional
    out, status = capture_stderr_and_exit do
      cmd_issues_status(["--number", "081", "--status", "needs_review", "--comment", "findings"])
    end
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  def test_status_fixed_requires_url
    out, status = capture_stderr_and_exit { cmd_issues_status(["034", "--status", "fixed"]) }
    assert_equal 1, status
    assert_match(/marking fixed requires --url/, out)
  end

  # A document fix (Google Doc, process change) carries no app/baseline — it must
  # not be forced to invent one. The command stops at the credential guard, so arg
  # validation is proven to pass without this test ever reaching the network.
  def test_status_fixed_with_url_alone_passes_arg_validation
    out, status = capture_stderr_and_exit { cmd_issues_status(["034", "--status", "fixed", "--url", "https://docs.google.com/d/1"]) }
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

  # ---- claimed -> fixed, adopted from merged PRs ----

  def merged_pr(repo: "acumen", number: 173, merged_at: "2026-07-20T05:09:05Z", title: "ISS-034: fix it")
    {
      "repo" => repo,
      "number" => number,
      "url" => "https://github.com/mbryzek/#{repo}/pull/#{number}",
      "title" => title,
      "merged_at" => merged_at,
    }
  end

  # A deployable stand-in: the adoption path only ever asks for name and repo_name.
  Deployable = Struct.new(:name, :repo_name)

  def registry_with(*apps)
    Struct.new(:deploy_tracked).new(apps)
  end

  def test_issue_numbers_in_title_finds_every_reference
    assert_equal %w[095 096],
                 issue_numbers_in_title("Chart hover robustness + engagement labels (ISS-095, ISS-096)")
  end

  def test_issue_numbers_in_title_dedupes_repeats
    assert_equal ["114"], issue_numbers_in_title("ISS-114: retry bound (closes ISS-114)")
  end

  # The padded three-digit display form is the contract. An unpadded or embedded
  # lookalike is not a reference, and matching one would mark the wrong issue fixed.
  def test_issue_numbers_in_title_ignores_lookalikes
    assert_empty issue_numbers_in_title("ISS-12: too short to be an issue number")
    assert_empty issue_numbers_in_title("MISS-114 is not a reference")
    assert_empty issue_numbers_in_title("no reference at all")
  end

  def test_adoptable_pr_takes_the_newest_merge_after_the_claim
    issue = graph_issue.merge("claimed_at" => "2026-07-19T00:00:00Z")
    prs = { "034" => [merged_pr(number: 9, merged_at: "2026-07-21T00:00:00Z"),
                      merged_pr(number: 8, merged_at: "2026-07-20T00:00:00Z")] }
    assert_equal 9, issue_adoptable_pr(issue, prs)["number"]
  end

  # A reopened issue keeps the PRs of its earlier rounds. Adopting one of those
  # would declare the CURRENT round fixed on the strength of work that shipped
  # before it was even claimed.
  def test_adoptable_pr_ignores_a_merge_that_predates_the_claim
    issue = graph_issue.merge("claimed_at" => "2026-07-25T00:00:00Z")
    prs = { "034" => [merged_pr(merged_at: "2026-07-20T00:00:00Z")] }
    assert_nil issue_adoptable_pr(issue, prs)
  end

  def test_adoptable_pr_takes_any_merge_when_the_issue_never_recorded_a_claim
    issue = graph_issue.reject { |k, _| k == "claimed_at" }
    prs = { "034" => [merged_pr(merged_at: "2020-01-01T00:00:00Z")] }
    refute_nil issue_adoptable_pr(issue, prs)
  end

  def test_adoptable_pr_is_nil_when_no_pr_names_the_issue
    assert_nil issue_adoptable_pr(graph_issue, { "099" => [merged_pr] })
  end

  # A repo that releases a tracked deployable gets the (app, baseline) pair, which
  # is what lets the deploy pass detect the release.
  def test_adoption_body_records_the_app_and_its_live_version_as_baseline
    registry = registry_with(Deployable.new("playbook-app", "playbook-app"))
    cache = { "playbook-app" => { "version" => "0.1.9" } }
    body = issue_adoption_body(registry, cache, merged_pr(repo: "playbook-app", number: 356))
    assert_equal "fixed", body[:status]
    assert_equal "https://github.com/mbryzek/playbook-app/pull/356", body[:url]
    assert_equal "playbook-app", body[:app]
    assert_equal "0.1.9", body[:baseline_version]
  end

  # acumen, devops and the shared libs carry fixes but release no tracked
  # deployable. Recording a document-style fix puts the issue in front of a human
  # in the deploy pass instead of leaving it stranded in `claimed`.
  def test_adoption_body_is_url_only_for_a_repo_with_no_deployable
    body = issue_adoption_body(registry_with, {}, merged_pr(repo: "acumen"))
    refute body.key?(:app)
    refute body.key?(:baseline_version)
  end

  # Fail-closed: an unreadable live version means no baseline rather than a guessed
  # one, since a wrong baseline is what would declare a fix live before it is.
  def test_adoption_body_omits_the_pair_when_the_live_version_is_unreadable
    registry = registry_with(Deployable.new("workers", "workers"))
    cache = { "workers" => { error: "unreachable" } }
    body = issue_adoption_body(registry, cache, merged_pr(repo: "workers"))
    refute body.key?(:app)
  end

  def test_adoption_note_names_the_pr_and_the_baseline
    body = { app: "playbook-app", baseline_version: "0.1.9" }
    assert_equal "playbook-app#356 merged (playbook-app baseline 0.1.9)",
                 issue_adoption_note(body, merged_pr(repo: "playbook-app", number: 356), false)
  end

  def test_adoption_note_says_the_merge_is_the_release_for_a_repo_that_ships_nothing
    assert_match(/devops releases nothing, so the merge is the release/,
                 issue_adoption_note({}, merged_pr(repo: "devops"), true))
  end

  def test_adoption_note_names_the_missing_issue_app_for_a_releasing_repo
    assert_match(/no issue app for acumen — advance once it releases/,
                 issue_adoption_note({}, merged_pr, false))
  end

  # devops, the shared libs and schema-evolution-manager have no version endpoint
  # that could ever advance the issue, so `fixed` there means stranded forever.
  def test_repo_releases_nothing_only_when_it_is_not_deploy_tracked
    registry = registry_with(Deployable.new("acumen", "acumen"))
    assert issue_repo_releases_nothing?(registry, "devops")
    refute issue_repo_releases_nothing?(registry, "acumen")
  end

  # The registry is the wider set: it tracks acumen, rallyd and a dozen others that
  # `issue_app` has no value for. Sending one of those as `app` is a 422, so the
  # adoption must not offer it — the issue lands `fixed` with no app instead.
  def test_adoption_body_omits_an_app_the_issue_tracker_cannot_name
    registry = registry_with(Deployable.new("acumen", "acumen"))
    cache = { "acumen" => { "version" => "0.9.99" } }
    body = issue_adoption_body(registry, cache, merged_pr(repo: "acumen"))
    refute body.key?(:app)
    assert_equal "https://github.com/mbryzek/acumen/pull/173", body[:url]
  end

  def test_issue_apps_are_the_playbook_deployables_only
    refute_includes ISSUE_APPS, "acumen"
    assert_equal %w[platform playbook-admin playbook-app playbook-www workers], ISSUE_APPS.sort
  end

  def test_adopt_summary_is_omitted_when_nothing_was_adopted
    assert_nil issues_adopt_summary(adopted: 0, apply: true)
  end

  def test_adopt_summary_counts_what_moved
    assert_equal "2 adopted from merged PRs.", issues_adopt_summary(adopted: 2, apply: true)
    assert_equal "2 would adopt from merged PRs.", issues_adopt_summary(adopted: 2, apply: false)
  end

  # Replace a top-level `dev` function for the duration of a block. The sweep must
  # never reach the network from a test — `gh` and the version probe here would
  # answer for the real org and the real production apps.
  def with_stubbed_function(name, impl)
    original = method(name)
    Object.send(:define_method, name, impl)
    yield
  ensure
    Object.send(:define_method, name, original)
  end

  def with_merged_prs(map, &block)
    with_stubbed_function(:issue_merged_prs_by_number, ->(**_kwargs) { map }, &block)
  end

  # Force the adoption payload, so the deploy-tracked landing can be exercised
  # without a live version probe.
  def with_adoption_body(body, &block)
    with_stubbed_function(:issue_adoption_body, ->(_registry, _cache, _pr) { body }, &block)
  end

  # The whole point of the backstop: an issue nobody marked fixed still moves.
  def test_reconcile_adopts_a_claimed_issue_whose_pr_merged
    claimed = [graph_issue.merge("claimed_at" => "2026-07-19T00:00:00Z")]
    out, = capture_io do
      with_merged_prs("034" => [merged_pr]) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => claimed,
                         "GET #{issues_list_path(statuses: 'fixed')}" => []) do
          cmd_issues_reconcile([])
        end
      end
    end
    assert_match(/^Claimed issues whose fix already merged/, out)
    assert_match(/would fix ISS-034 <- acumen#173 merged/, out)
    assert_match(/1 would adopt from merged PRs\./, out)
    assert_match(/Re-run with --apply/, out)
  end

  # ISS-127's shape: devops merges, releases nothing, and its issue would otherwise
  # wait on a release that is never coming. Straight to `deployed` — the state that
  # means "awaiting verification" — is the whole point of the merge-is-the-release
  # path.
  def test_reconcile_sends_a_repo_that_releases_nothing_straight_to_deployed
    claimed = [graph_issue.merge("claimed_at" => "2026-07-19T00:00:00Z")]
    out, = capture_io do
      with_merged_prs("034" => [merged_pr(repo: "devops", number: 241)]) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => claimed,
                         "GET #{issues_list_path(statuses: 'fixed')}" => []) do
          cmd_issues_reconcile([])
        end
      end
    end
    assert_match(/would deploy ISS-034 <- devops#241 merged; devops releases nothing/, out)
  end

  # Dry-run above wrote nothing; --apply is what records the transition. The stub
  # flunks on any request it was not told about, so the PUT being answered here IS
  # the assertion that it was sent.
  def test_reconcile_apply_records_the_adoption
    claimed = [graph_issue.merge("claimed_at" => "2026-07-19T00:00:00Z")]
    out, = capture_io do
      with_merged_prs("034" => [merged_pr]) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => claimed,
                         "GET #{issues_list_path(statuses: 'fixed')}" => [],
                         "PUT #{issues_path('/034/status')}" => graph_issue.merge("status" => "fixed")) do
          cmd_issues_reconcile(["--apply"])
        end
      end
    end
    assert_match(/fixed    ISS-034 <- acumen#173 merged/, out)
    assert_match(/1 adopted from merged PRs\./, out)
    refute_match(/Re-run with --apply/, out)
  end

  # A fix in a repo that DOES release a tracked deployable stops at `fixed` — the
  # deploy pass owns the rest, once that app ships past the baseline.
  def test_reconcile_adoption_stops_at_fixed_for_a_deploy_tracked_repo
    claimed = [graph_issue.merge("claimed_at" => "2026-07-19T00:00:00Z")]
    pr = merged_pr(repo: "playbook-app", number: 356)
    body = { status: "fixed", url: pr["url"], app: "playbook-app", baseline_version: "0.1.9" }
    out, = capture_io do
      with_merged_prs("034" => [pr]) do
        with_adoption_body(body) do
          with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => claimed,
                           "GET #{issues_list_path(statuses: 'fixed')}" => []) do
            cmd_issues_reconcile([])
          end
        end
      end
    end
    assert_match(/would fix ISS-034 <- playbook-app#356 merged \(playbook-app baseline 0\.1\.9\)/, out)
  end

  # A claimed issue with no merged PR is work in flight, not a miss.
  def test_reconcile_says_nothing_about_claimed_issues_without_a_merged_pr
    out, = capture_io do
      with_merged_prs({}) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [graph_issue],
                         "GET #{issues_list_path(statuses: 'fixed')}" => []) do
          cmd_issues_reconcile([])
        end
      end
    end
    assert_equal "", out
  end

  # ---- fixed -> deployed for a repo that releases nothing ----

  def fixed_via_pr(repo:, number: 246)
    graph_issue.merge(
      "status" => "fixed",
      "fixed_at" => "2026-07-30T15:00:00Z",
      "fixes" => [{ "url" => "https://github.com/mbryzek/#{repo}/pull/#{number}" }],
    )
  end

  def test_fix_repo_is_read_from_the_latest_fix_url
    assert_equal "devops", issue_fix_repo(fixed_via_pr(repo: "devops"))
  end

  # A reopened issue accumulates fixes; the latest one is the release that matters,
  # matching issue_fix_deployment.
  def test_fix_repo_uses_the_latest_fix
    issue = graph_issue.merge("fixes" => [
                                { "url" => "https://github.com/mbryzek/acumen/pull/1" },
                                { "url" => "https://github.com/mbryzek/devops/pull/2" },
                              ])
    assert_equal "devops", issue_fix_repo(issue)
  end

  # A Google Doc describing a manual fix has no repo and no release to infer. Those
  # are the fixes the skip line was written for, and they must keep skipping.
  def test_fix_repo_is_nil_for_a_document_fix
    assert_nil issue_fix_repo(graph_issue.merge("fixes" => [{ "url" => "https://docs.google.com/document/d/abc" }]))
    assert_nil issue_fix_repo(graph_issue)
  end

  def test_fix_repo_ignores_a_pr_outside_the_org
    assert_nil issue_fix_repo(graph_issue.merge("fixes" => [{ "url" => "https://github.com/someoneelse/devops/pull/9" }]))
  end

  # ISS-131's own shape: marked fixed by hand with a devops PR, then stranded,
  # because the deploy pass had no rule for a repo that never releases.
  def test_deploy_pass_advances_a_fix_in_a_repo_that_releases_nothing
    out, = capture_io do
      with_merged_prs({}) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [],
                         "GET #{issues_list_path(statuses: 'fixed')}" => [fixed_via_pr(repo: "devops")]) do
          cmd_issues_reconcile([])
        end
      end
    end
    assert_match(/would deploy ISS-034 \(devops releases nothing — the merge is the release\)/, out)
    refute_match(/advance manually/, out)
  end

  # acumen releases; claiming its merge is live would be a lie the auto-verifier
  # then acts on. It keeps skipping to a human.
  def test_deploy_pass_still_skips_a_fix_in_a_repo_that_does_release
    out, = capture_io do
      with_merged_prs({}) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [],
                         "GET #{issues_list_path(statuses: 'fixed')}" => [fixed_via_pr(repo: "acumen")]) do
          cmd_issues_reconcile([])
        end
      end
    end
    assert_match(/skip ISS-034: no deploy info \(document fix — advance manually\)/, out)
  end

  def test_deploy_pass_apply_records_the_merge_is_the_release_transition
    out, = capture_io do
      with_merged_prs({}) do
        with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [],
                         "GET #{issues_list_path(statuses: 'fixed')}" => [fixed_via_pr(repo: "devops")],
                         "PUT #{issues_path('/034/status')}" => graph_issue.merge("status" => "deployed")) do
          cmd_issues_reconcile(["--apply"])
        end
      end
    end
    assert_match(/deployed ISS-034 \(devops releases nothing/, out)
    assert_match(/1 deployed, 0 skipped, 1 fixed total\./, out)
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

  # Regression (2026-07-27): this file ran with a live credential in the process.
  # Inside a Claude session `dev` presents the AI's API token, and
  # `require_playbook_session!` accepts it, so the arg-validation tests sailed past
  # the guard and wrote to PRODUCTION ISS-034 on every run — dozens of snooze
  # comments, a verified→fixed regression, and 35 bogus fixes. Stubbing the session
  # was never enough; only blocking the request is. Assert that WITH a credential.
  def test_a_credentialed_issue_command_still_cannot_reach_production
    with_credentials do
      err = assert_raises(DevTestSupport::NetworkBlocked) do
        cmd_issues_snooze(["034", "--days", "1", "--comment", "must never reach the network"])
      end
      assert_match(%r{PUT /playbook/issues/034/snooze}, err.message)
    end
  end

  # The trap itself, stated as a test: the guard is satisfied by the AI's API
  # TOKEN, not only by a human session. A test that nils the session therefore
  # still runs the command for real — which is why the block above blocks the
  # request rather than the credential.
  def test_the_ai_token_alone_satisfies_the_playbook_credential_guard
    orig = ApiClient.method(:auth_header_for)
    ApiClient.define_singleton_method(:auth_header_for) { |_app, use_localhost:| ["Authorization", "Basic token"] }
    _, status = capture_stderr_and_exit { require_playbook_session!(false) }
    assert_nil status, "a token-bearing process passes the guard even with no session"
  ensure
    ApiClient.define_singleton_method(:auth_header_for, orig)
  end

  def test_require_playbook_session_names_exact_login_command
    out, status = capture_stderr_and_exit { require_playbook_session!(false) }
    assert_equal 1, status
    assert_match(/dev auth login --app playbook/, out)
  end

  def test_require_playbook_session_localhost_names_localhost_login_command
    out, status = capture_stderr_and_exit { require_playbook_session!(true) }
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
      out, status = capture_stderr_and_exit { cmd_issues_claim(["--category", category]) }
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

  # ---- dev issues create: claim_on_create ----

  # `dev issues create` must always ask the server to claim what it files, atomically —
  # stub issue_file_claim_and_start itself (the codebase's own established boundary:
  # its network + plan-writing side effects are not exercised by this suite, see
  # `write_manual_issue_plan`/the module comment at the top of this file) rather than
  # driving the full HTTP + editor + file-write path.
  def test_create_requests_claim_on_create
    captured = nil
    define_singleton_method(:issue_edit_in_editor) { "Investigate the export bug" }
    define_singleton_method(:issue_file_claim_and_start) do |**kwargs|
      captured = kwargs
      { "number" => "099" }
    end
    # tty: true pins this to the editor path it stubs — on a non-terminal stdin the
    # brief would come from stdin instead, and which branch ran would depend on how
    # the suite was invoked.
    with_credentials do
      with_stdin("", tty: true) do
        cmd_issues_create(["--category", "bug", "--title", "Export bug", "--no-spawn"])
      end
    end
    refute_nil captured
    assert_equal true, captured.fetch(:form).fetch(:claim_on_create)
  end

  # ---- dev issues create: filing without a terminal ----

  # The whole point of --body: a caller with no terminal (a Claude session filing the
  # work it is already doing, cron, `claude --print`) can file an issue. Before this,
  # `create` shelled out to $EDITOR unconditionally, so every headless run died on
  # `vi` — "Editor `vi` exited non-zero. Nothing filed."
  def test_create_takes_the_brief_from_body_without_opening_an_editor
    captured = nil
    define_singleton_method(:issue_edit_in_editor) { flunk("opened $EDITOR despite --body") }
    define_singleton_method(:issue_file_claim_and_start) do |**kwargs|
      captured = kwargs
      { "number" => "099" }
    end
    with_credentials do
      with_stdin("", tty: false) do
        cmd_issues_create(["--category", "bug", "--body", "CSV export drops the last row", "--no-spawn"])
      end
    end
    assert_equal "CSV export drops the last row", captured.fetch(:form).fetch(:body)
  end

  # A --body is content, not an editor buffer, so `#` lines are NOT instructions to
  # strip: markdown headings in a brief have to survive verbatim.
  def test_create_keeps_markdown_headings_in_a_body
    captured = nil
    define_singleton_method(:issue_file_claim_and_start) do |**kwargs|
      captured = kwargs
      { "number" => "099" }
    end
    brief = "## Steps\n1. Export\n\n## Expected\nAll rows"
    with_credentials do
      with_stdin("", tty: false) do
        cmd_issues_create(["--category", "bug", "--body", brief, "--no-spawn"])
      end
    end
    assert_equal brief, captured.fetch(:form).fetch(:body)
  end

  # The unix half of the same escape hatch: with no --body and no terminal, stdin IS
  # the brief.
  def test_create_takes_the_brief_from_piped_stdin
    captured = nil
    define_singleton_method(:issue_edit_in_editor) { flunk("opened $EDITOR on a non-terminal stdin") }
    define_singleton_method(:issue_file_claim_and_start) do |**kwargs|
      captured = kwargs
      { "number" => "099" }
    end
    with_credentials do
      with_stdin("Worker retries forever on a 404\n", tty: false) do
        cmd_issues_create(["--category", "bug", "--no-spawn"])
      end
    end
    assert_equal "Worker retries forever on a 404", captured.fetch(:form).fetch(:body)
  end

  # No --body, no terminal, nothing piped: name the flag to reach for. The old
  # failure here was a screenful of vim escape codes, which read as "the tool is
  # broken" rather than "you have to pass a brief".
  def test_create_without_a_terminal_or_a_body_says_which_flag_to_pass
    define_singleton_method(:issue_edit_in_editor) { flunk("opened $EDITOR on a non-terminal stdin") }
    define_singleton_method(:issue_file_claim_and_start) { |**| flunk("filed an issue with no brief") }
    out, status = capture_stderr_and_exit do
      with_credentials { with_stdin("", tty: false) { cmd_issues_create(["--category", "bug"]) } }
    end
    assert_equal 1, status
    assert_includes out, "--body"
  end

  # The other prompt in this command. Ask.select_from_list re-asks itself on an
  # answer it cannot parse, so on EOF it would recurse forever instead of failing —
  # never reach it without a terminal.
  def test_create_without_a_terminal_requires_an_explicit_category
    define_singleton_method(:issue_file_claim_and_start) { |**| flunk("filed an issue with no category") }
    out, status = capture_stderr_and_exit do
      with_credentials { with_stdin("Some brief", tty: false) { cmd_issues_create(["--body", "Some brief"]) } }
    end
    assert_equal 1, status
    assert_includes out, "--category is required"
  end

  # ---- dev issues create: --no-spawn writes no session scaffolding ----

  # --no-spawn means no session is coming, so the session id and the plan are both
  # wrong to write: the uuid would leave `dev issues resume` pointing at a Claude
  # session that never existed, and the plan is a brief for a fresh session when the
  # caller filing the issue is the one already working it. Only the create POST is
  # stubbed — a session comment POST would fail the test as an unstubbed request.
  def test_no_spawn_records_no_session_and_writes_no_plan
    define_singleton_method(:write_manual_issue_plan) { |*| flunk("wrote a plan for a session that will not run") }
    filed = { "number" => "099", "status" => "claimed" }
    out = nil
    with_stubbed_api("POST /playbook/issues" => filed) do
      out = capture_stdout do
        issue_file_claim_and_start(
          endpoint: "https://example.test", form: { category: "bug", claim_on_create: true },
          category: "bug", spawn_session: false
        )
      end
    end
    assert_includes out, "Filed ISS-099 (bug)"
    assert_includes out, "no session started"
    refute_includes out, "reattach later"
    refute_includes out, "Start it with"
  end

  # What the filer actually needs next is how to close the issue — it is already
  # claimed, and `dev issues claim` only offers OPEN issues, so the way back into
  # the queue has to be printed too or the issue looks stranded.
  def test_no_spawn_prints_how_to_close_the_issue
    define_singleton_method(:write_manual_issue_plan) { |*| flunk("wrote a plan for a session that will not run") }
    out = nil
    with_stubbed_api("POST /playbook/issues" => { "number" => "099" }) do
      out = capture_stdout do
        issue_file_claim_and_start(
          endpoint: "https://example.test", form: { category: "bug", claim_on_create: true },
          category: "bug", spawn_session: false
        )
      end
    end
    assert_includes out, "dev issues status 099 --status fixed"
    assert_includes out, "dev issues status 099 --status open"
  end

  # ---- dev issues list (read-only) ----

  def test_list_prints_every_status_by_default
    issues = [
      { "number" => "010", "status" => "open", "category" => "bug", "title" => "Chart empty" },
      { "number" => "012", "status" => "verified", "category" => "feature", "title" => "Add export" },
    ]
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: [])}" => issues) do
        cmd_issues_list([])
      end
    end
    assert_match(/ISS-010/, out)
    assert_match(/ISS-012/, out)
  end

  def test_list_prints_no_issues_found_when_empty
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: [])}" => []) do
        cmd_issues_list([])
      end
    end
    assert_match(/No issues found\./, out)
  end

  def test_list_filters_to_repeated_status_flags
    issues = [
      { "number" => "010", "status" => "open", "category" => "bug", "title" => "Chart empty" },
      { "number" => "011", "status" => "claimed", "category" => "feature", "title" => "Add export" },
    ]
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: %w[open claimed])}" => issues) do
        cmd_issues_list(["--status", "open", "--status", "claimed"])
      end
    end
    assert_match(/ISS-010/, out)
    assert_match(/ISS-011/, out)
  end

  def test_list_filters_by_category_and_explicit_status
    issues = [{ "number" => "020", "status" => "fixed", "category" => "bug", "title" => "x" }]
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: %w[fixed], category: 'bug')}" => issues) do
        cmd_issues_list(["--category", "bug", "--status", "fixed"])
      end
    end
    assert_match(/ISS-020/, out)
  end

  def test_list_rejects_an_invalid_status
    out, status = capture_stderr_and_exit { cmd_issues_list(["--status", "bogus"]) }
    assert_equal 1, status
    assert_match(/--status must be one or more of/, out)
  end

  def test_list_rejects_an_invalid_category
    out, status = capture_stderr_and_exit { cmd_issues_list(["--category", "bogus"]) }
    assert_equal 1, status
    assert_match(/--category must be one of/, out)
  end

  def test_a_credentialed_issue_list_still_cannot_reach_production
    with_credentials do
      err = assert_raises(DevTestSupport::NetworkBlocked) do
        cmd_issues_list([])
      end
      assert_match(%r{GET /playbook/issues}, err.message)
    end
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

  # ---- output ----

  # Same reason as the features reconciler: `release` runs this unattended, so the
  # ISS-nnn lines need a header saying what sweep they came from.
  def test_reconcile_titles_its_output
    fixed = [{ "number" => "034", "status" => "fixed" }]
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [],
                       "GET #{issues_list_path(statuses: 'fixed')}" => fixed) do
        cmd_issues_reconcile([])
      end
    end
    assert_match(/^Fixed issues awaiting deploy\b/, out)
    assert_match(/skip ISS-034/, out)
    # Nothing transitioned, so the counts add nothing the skip line did not say.
    refute_match(/fixed total/, out)
  end

  # Nothing fixed is the normal state between releases; the sweep says nothing
  # rather than printing a "nothing to do" line into every release.
  def test_reconcile_prints_nothing_when_no_issues_are_awaiting_deploy
    out, = capture_io do
      with_stubbed_api("GET #{issues_list_path(statuses: 'claimed')}" => [],
                       "GET #{issues_list_path(statuses: 'fixed')}" => []) do
        cmd_issues_reconcile([])
      end
    end
    assert_equal "", out
  end

  # ---- issues_reconcile_summary ----

  def test_issues_summary_is_omitted_when_nothing_was_advanced
    assert_nil issues_reconcile_summary(deployed: 0, skipped: 2, total: 2, apply: true)
  end

  def test_issues_summary_counts_when_something_advanced
    assert_equal "1 deployed, 2 skipped, 3 fixed total.",
                 issues_reconcile_summary(deployed: 1, skipped: 2, total: 3, apply: true)
    assert_equal "1 would deploy, 2 skipped, 3 fixed total.",
                 issues_reconcile_summary(deployed: 1, skipped: 2, total: 3, apply: false)
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
