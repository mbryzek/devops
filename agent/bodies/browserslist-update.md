# Update caniuse-lite across the JS repos

`caniuse-lite` is the browser-support table every JS build reads through
browserslist, and it goes stale on its own — nothing in any repo changes, the
data does. `dev browserslist update --check` says which repos are behind; your
job is to run it, stop if none are, and open a PR per repo that is.

**This issue is filed unconditionally, every Monday, WITHOUT anyone having
looked first.** It is not evidence that any repo is behind. Run the check before
you form any view of what needs doing.

## 1. Check first — and stop here if it is clean

    dev browserslist update --check

It shallow-clones every `~/code/*` repo that has a `package.json`, runs
`npx update-browserslist-db@latest` in each clone, and reports which ones the
updater rewrote. It commits nothing and pushes nothing.

Its verdict is its exit code — the same contract every producer check uses:

| Exit | Means | Do |
|---|---|---|
| 0 | every repo's caniuse-lite is current | **dismiss and stop**, below |
| 1 | repos are behind; they are named on stdout | section 2 |
| 2 | the check could not run; nothing was concluded | section 3 |

Clean is a **successful run**, not a wasted one:

    dev issues status <n> --status dismissed --comment "dev browserslist update --check exited 0 — caniuse-lite is current in every JS repo. No PR needed."

Then stop. Do not open a PR and do not go looking for other work — this issue's
whole scope is that one question.

`dismissed` and not `fixed` deliberately: a no-op run must leave a TERMINAL
issue. `fixed` and `deployed` are both non-terminal for producer dedup, so
closing this `fixed` would suppress next Monday's run, and the one after, until
someone clicked verify.

The check works in `~/code/browserslist.<YYYYMMDD>`, which it creates, purges
and owns. That is the command's scratch space, not a repo checkout and not this
session's workspace — let it manage that directory, and do not treat it as
working outside your workspace.

## 2. Repos are behind — one PR each

The bare `dev browserslist update` (no `--check`) exists, and you must NOT run
it: it pushes straight to `main` in every repo it touches. That is what this
producer used to do from inside the tick, with no review, and moving the work
into a claimed session is precisely so the change goes through a PR. Do it the
normal way instead, per repo named by the check:

1. `gh repo clone mbryzek/<repo> <workspace>/<repo>` — a FULL clone into the
   workspace directory this session was given, never `--depth`, and never a
   checkout under `~/code/<repo>` (those are Mike's working trees).
2. `git fetch origin && git checkout -b <this session's branch> origin/main`.
3. `npx --yes update-browserslist-db@latest` in the clone.
4. `git diff` — confirm the ONLY changes are the lockfile's `caniuse-lite`
   entries. This is the part a script could not do. Anything else in the diff
   (a dependency bump the updater pulled in, an unrelated lockfile rewrite) is a
   finding to report here, not something to ship quietly.
5. Commit, push, and open the PR:

       gh pr create --draft --title "ISS-<n>: Update caniuse-lite (<repo>)"
       gh pr ready <pr>

   No `--base` — it defaults to main, and passing it is how stacked PRs happen.

Repos are independent: one that fails to clone or whose diff looks wrong does
not stop the others. Do every repo the check named, then report all of them.

Close out with the first PR's URL:

    dev issues status <n> --status fixed --url "<PR URL>"

List every repo and its PR (or its reason for having none) in the comment.

## 3. The check itself broke (exit 2)

Exit 2 says nothing was concluded — a clone failed, `npx` failed, or no repo was
examined at all. It is not evidence that the repos are current, and not evidence
that they are behind.

Read the captured failure output the check prints (or re-run it with
`--verbose`), and report the repo and the reason here. A transient clone failure
is worth one retry. If the cause needs a decision, or points at a bug in
`dev browserslist update`, close this issue `--status needs_input` with the
specific question, or file the bug with `dev issues create --category bug
--status open` and dismiss this one naming that issue.
