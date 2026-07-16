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

## Decoding the issue

- The **title** is the admin's one-line complaint; the **body** carries what they typed.
  Find the chart by grepping the GraphCard title they name:
  `grep -rin "revenue by type" src/routes/graphs/`.
- **Attachments are ground truth.** An in-app capture uploads the automatic screenshot as the
  FIRST attachment, and its description carries the rendering context: the page url (with the
  exact filters/date range the admin was viewing), the chart, and the viewport. Any later
  attachment is an image the admin chose to add (their own screenshot, an annotated capture);
  those usually show the problem more directly than the automatic snapshot.
- Local session DBs are schema-only (no prod data), so curl every attachment url into your
  working dir and LOOK at the images before theorizing.
- **Club** (when present) is the club the admin was viewing — reproduce against that club's
  shape of data.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first.
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-graphs-<date>`);
   clone `clubaid-app` (and `platform` + `devops` sibling only if the fix is backend/codegen).
   Never edit `~/code/clubaid-app` or `~/code/platform` directly.
3. Group related issues into one branch/PR; unrelated fixes may share the branch too —
   these are small dashboard fixes, one PR set per run is fine.
4. Verify: `npm run check` + `npm run test:unit` (clubaid-app); scoped `sbt` specs for any
   platform change; visual pass with the `browse` tool against your own dev server (never
   Mike's running servers).
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
