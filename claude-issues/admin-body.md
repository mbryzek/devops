## How this pipeline works

- **Frontend**: repo `mbryzek/clubaid-admin` (Elm + Tailwind) — the internal admin console.
  Pages under `src/Page/`, routes in `src/Route.elm` / `src/Urls.elm`, API access through the
  generated client in `src/Generated/`.
- **Backend**: repo `mbryzek/platform` (Scala 3 / Play), the `clubaid/` subproject; contract in
  `platform/spec/clubaid-admin.json`. The console regenerates its Elm client from that spec, so
  a wrong/missing field on a page is often a spec question.
- Note `clubaid-admin` (this console) and `clubaid-app` (the member app, category `app`) are
  two different apps — make sure the issue is about the console before touching it.

## Decoding the issue

- The **title** is the one-line complaint; the **body** carries the detail the reporter typed.
- **Attachments are ground truth.** An in-app capture uploads the automatic screenshot as the
  FIRST attachment, with the page url and viewport in its description. Curl every attachment
  url into your working dir and LOOK at the images before theorizing — local session DBs are
  schema-only (no prod data).
- **Club** (when present) is the club being administered when the issue was filed.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first
   (especially `elm.development.mdc`, `elm.general.mdc`, `elm.route.mdc`).
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-admin-<date>`);
   clone `clubaid-admin` (and `platform` + `devops` sibling only if the fix is backend/codegen).
   Never edit `~/code/clubaid-admin` or `~/code/platform` directly.
3. Group related issues into one branch/PR; unrelated fixes may share the branch too —
   one PR set per run is fine.
4. Verify: the Elm build plus `./review.sh` (elm-review) — required after any Elm change;
   scoped `sbt` specs for any platform change; visual pass with the `browse` tool against your
   own dev server (never Mike's running servers).
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow. clubaid-admin's Reviewable review auto-completes (Mike does not review
   frontend).
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
