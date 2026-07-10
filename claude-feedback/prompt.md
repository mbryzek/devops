# Fix claimed graph-feedback items (ClubAid dashboards)

You are a headless fix session started by `claude-feedback-fix`. An admin left feedback
comments on the ClubAid graph dashboards; they have been atomically claimed for you.
Fix them and open PRs, then mark each item's outcome. Work autonomously — there is no
human to ask; use `needs_input` (below) when you genuinely cannot proceed.

## Your inputs (environment)

- `$CLAUDE_FEEDBACK_CLAIMED_FILE` — JSON array of the claimed feedback comments
  (id, club, page_url, chart_key, comment, viewport, screenshot {url}, created_at).
- `$CLAUDE_FEEDBACK_API_BASE` + `$CLAUDE_FEEDBACK_SESSION_ID` — for status updates:
  ```bash
  curl -sf -X PUT "$CLAUDE_FEEDBACK_API_BASE/playbook/feedback/comments/<id>/status" \
    -H "session_id: $CLAUDE_FEEDBACK_SESSION_ID" -H 'Content-Type: application/json' \
    -d '{"status": "fixed", "note": "<PR URL>"}'
  ```

## How this pipeline works

- **Frontend**: repo `mbryzek/clubaid-app` (SvelteKit, app.clubaid.co). Dashboard pages under
  `src/routes/graphs/` (member, financial, court, staff, forecasting, ...); each page's
  `+page.server.ts` fetches aggregates via the generated playbook client
  (`src/generated/com-bryzek-playbook.ts`) and streams them un-awaited (`streamAggregate`).
- **Chart cards**: every chart renders in `src/lib/charts/GraphCard.svelte` wrapping a
  primitive from `src/lib/charts/` (StackedBar, MultiSeriesLine, YoYDualLine, GroupedBar,
  HorizontalBar, DivergingBar, Donut, RankedZipList, ...). D3 scales; custom SVG.
- **Backend**: repo `mbryzek/platform`, subproject `playbook/` (Scala 3 / Play); aggregate
  endpoints in `spec/playbook.json`, implemented under `platform/playbook/app/`.

## Decoding the feedback context

- `chart_key` is the slugified GraphCard `title` (`src/lib/feedback/context.ts`). Find the
  chart by grepping the title text: `grep -rin "revenue by type" src/routes/graphs/`.
- `page_url` carries the exact filters/date range the admin was viewing.
- **Screenshots are ground truth.** Local session DBs are schema-only (no prod data), so
  download each item's `screenshot.url` (curl, with the session_id header if required)
  into your working dir and LOOK at it before theorizing.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first.
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `gf-fix-<date>`);
   clone `clubaid-app` (and `platform` + `devops` sibling only if the fix is backend/codegen).
   Never edit `~/code/clubaid-app` or `~/code/platform` directly.
3. Group related items into one branch/PR; unrelated fixes may share the branch too —
   these are small dashboard fixes, one PR set per run is fine.
4. Verify: `npm run check` + `npm run test:unit` (clubaid-app); scoped `sbt` specs for any
   platform change; visual pass with the `browse` tool against your own dev server (never
   Mike's running servers).
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Per item outcome (do this — items must not stay `claimed`):
   - fixed in a PR → status `fixed`, note = full PR URL
   - can't act without a human decision → status `needs_input`, note = your specific question
   - clearly not actionable / already fixed → status `needs_input`, note explaining why
7. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
