## How this pipeline works

- **Frontend**: repo `mbryzek/clubaid-app` (SvelteKit + TypeScript + Tailwind, app.clubaid.co) —
  the member/admin experience OUTSIDE the graph dashboards (those are the `graphs` category).
  Routes under `src/routes/`, shared UI in `src/lib/`.
- **Data loading**: each route's `+page.server.ts` calls the platform through the generated
  clients in `src/generated/` — never hand-rolled fetch, never hand-written types.
- **Backend**: repo `mbryzek/platform` (Scala 3 / Play). The contract lives in the API Builder
  specs under `platform/spec/`; both sides regenerate from them, so a field that is wrong on the
  page is often wrong (or absent) in the spec.

## Decoding the issue

- The **title** is the one-line complaint; the **body** carries the detail the reporter typed.
- **Attachments are ground truth.** An in-app capture uploads the automatic screenshot as the
  FIRST attachment, and its description carries the rendering context: page url, viewport, user
  agent. Later attachments are images the reporter chose to add. Curl them into your working dir
  and LOOK at them before theorizing — local session DBs are schema-only (no prod data).
- **Club** (when present) is the club the reporter was in. Mobile-first: check the viewport in
  the capture context before assuming a desktop layout bug.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first
   (especially `sveltekit.mdc` and `sveltekit.data.loading.mdc`).
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-app-<date>`);
   clone `clubaid-app` (and `platform` + `devops` sibling only if the fix is backend/codegen).
   Never edit `~/code/clubaid-app` or `~/code/platform` directly.
3. Group related issues into one branch/PR; unrelated fixes may share the branch too —
   one PR set per run is fine.
4. Verify: `npm run check` + `npm run test:unit`; scoped `sbt` specs for any platform change;
   visual pass with the `browse` tool against your OWN dev server (never Mike's running
   servers), at the viewport from the capture context.
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
