# Weekly per-repo quality review

**The repo under review is named in this issue's title** (`Weekly code review: <repo>`).
Everything below is the standing playbook for that repo.

You are a detail-oriented staff software architect. Review the last week of
changes and **ship the fixes**. Read and obey `~/code/CLAUDE.md` and the relevant
`~/code/claude/rules/*.mdc`. Work end-to-end without asking.

## Posture: full-auto

Implement and open PRs for everything you are confident in, **including
behavior-changing fixes** — but call out every behavior change explicitly in its
PR body so it can be vetoed.

Two things you must NOT auto-ship. Open a draft PR or file a separate issue and
flag them instead:

- a fix that would revert a deliberate, commit-message-documented decision
- a systemic / financial / high-blast-radius change, especially one a prior
  author already dismissed in review

Surface those with evidence and let a human decide.

## 1. Setup

Never work in `~/code/<repo>` directly.

- Feature dir under `~/code/ai/` with a SHORT name (≤19 chars), e.g. `~/code/ai/wk-<repo>-<mmdd>`.
- Full clone from GitHub over SSH — never `--depth`.
- Baseline is the commit ~7 days ago:

      BASE=$(git -C <clone> rev-list -1 --before="7 days ago" origin/main)
      HEAD=$(git -C <clone> rev-parse origin/main)
      N=$(git -C <clone> rev-list --count $BASE..$HEAD)

**Pick the scope from N**, and never exit early just because the week was thin:

- **N ≥ 8** — normal weekly-window review over `BASE..HEAD`.
- **N < 8 (including N = 0)** — escalate to a **full-repo review**. There is no
  diff to lean on, so read the actual source across the repo (excluding
  `generated/`, vendored deps, `node_modules`, build output), using `git log`
  only for intent. Prioritize by blast radius so the pass stays bounded: core
  domain/service/DAO logic, money/auth/permissions paths, task processors,
  shared libs, and anything touched in the last ~90 days first. Deep-reviewing
  the highest-risk subset is acceptable — say which areas were covered and which
  were deferred. A quiet week is exactly when a broader audit pays.

Establish a **clean baseline build before touching anything**, so later failures
are attributable to your change. Detect the stack from the repo (`build.sbt`,
`elm.json`, `package.json` + svelte, `Gemfile`, `*.pkl`).

## 2. Review

Fan out one reviewer per subproject or theme. In weekly-window mode each reviewer
works over `BASE..HEAD` reading the CURRENT code plus `git diff`/`git log` for
intent; in full-repo mode each reads its assigned area's source in full.

**Verify against HEAD, not the diff hunk.** A later commit in the same week has
often already fixed what a diff appears to show.

Reviewers return structured findings (type, severity, `file:line`, proposed fix,
behavior-changing, confidence). **Pipeline each reviewer into an adversarial
verifier** that confirms the finding is real AND is not an intentional decision —
read the commit message that introduced it. Drop false positives and verified
intentional decisions.

Conventions checklist for the reviewers: no wildcard `case _` (even
Option/Either-wrapped), zero-tolerance DRY, no `@scala.annotation.unused`, no
`Thread.sleep`, generated DAO insert/update returns the record (no re-fetch),
task processor idempotency, `ValidatedNec[String, T]` for low-level clients,
`TimeZoneUtil` not `DateTimeZone.forID`, named case classes over tuples, no
session id in query params, lib-query gotchas, N+1 / aggregate-in-SQL /
unbounded-memory / regex-in-loop perf, a missing index for a new filter.
**Never hand-edit anything under `generated/`** — fix the codegen template.

## 3. Triage into independent PRs

Group confirmed findings into coherent, INDEPENDENT PRs, each branched off
`origin/main` with a DISJOINT file set. No stacked PRs — these repos squash-merge.
Keep critical items as their own tight PRs so they merge fast. Branch names ≤19
chars. Write the full findings report and PR grouping to
`~/code/claude/plans/<repo>-weekly-<date>.md`.

## 4. Per PR

Follow CLAUDE.md's "when work is done" in full:

1. `git fetch origin`; branch off `origin/main`.
2. Implement the fix plus DRY, high-level tests — read the existing tests first
   and match their shape.
3. Compile and run the AFFECTED specs only. **There is no CI in these repos, so
   you run the tests.** Use this session's Dockerized database via the
   `session-db` skill — never Mike's local DB on `:5432`, and never a URL you did
   not get from `claude-db start`. Tests truncate. If a spec fails, run the SAME
   spec on `origin/main` to decide whether it is pre-existing or yours — never
   change production behavior to make a test pass.
4. Commit, push, open a **draft** PR (`gh pr create --draft`; never pass
   `--base`). PR body: what and why, behavior-change flags, verification, finding
   ids. Prefix the title with this issue's number: `ISS-<n>: <title>`.
5. `gh pr ready <pr>`. Human review happens in Reviewable, which every open PR
   gets automatically — do NOT run the old `code-reviewer` agent and
   `code-review` skill rounds as gates, and never report a Reviewable URL.
6. Rebase onto latest `origin/main`; rerun codegen if specs changed (`api`
   regenerates apibuilder and DAO specs in one pass, plus elm/svelte builds); fix
   any drift; force-push after fetching.

Do NOT merge — leave PRs ready for Mike.

## 5. Safety

- Never `> somefile` with a command that might fail; it truncates on failure.
  `git status` before every commit and restore any stray or emptied tracked file.
- Verify findings against ground truth — the actual code and codegen — before
  acting. Trust the compiler and the parser over memory.
- After ANY behavior-changing fix, run the Munger inversion: "how could this
  silently break or mis-report in production?" Add a test pinning the intended
  behavior.

## 6. Output

Write the summary to
`/Users/mbryzek/code/openclaw/openclaw-workspace/data/weekly-review-latest.md`,
in exactly this format. **The morning briefing parses this file**, and it keys on
the `# Weekly Review: <repo> — <date>` header line, so that line must always name
the repo:

    # Weekly Review: <repo> — <YYYY-MM-DD>

    ## PRs Opened
    - [#<n> title](<github_url>) — <one-line description> [BEHAVIOR CHANGE: <what>]

    ## Flagged (Not Auto-Shipped)
    - <finding> — <reason not shipped> — <draft PR or issue link>

    ## Scope Note
    (only when a full-repo review ran because the weekly window was thin)
    Full-repo review — only <N> commits this week. Areas covered: <list>.
    Deferred to next run: <list>.

    ## Feature Dir
    ~/code/ai/<dir-name>

    ## Plan File
    ~/code/claude/plans/<repo>-weekly-<date>.md

Omit the `[BEHAVIOR CHANGE]` tag where there is none. If no PRs were opened and
nothing was flagged, still write the file with empty sections so the briefing
knows the job ran.

Then close this issue out per CLAUDE.md — `dev issues status <n> --status fixed
--url "<PR URL>"` — pointing at the most significant PR, or at the plan file if
the week produced no PR at all. Save durable, non-obvious lessons as memory files
with a one-line `MEMORY.md` pointer, and correct any memory you found to be wrong.
