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
  download each item's screenshot url (curl) into your working dir and LOOK at it before
  theorizing.

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
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
