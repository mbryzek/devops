# Fix the failing supply-chain config checks

`dev depsguard` scans the supply-chain settings that decide what a package
manager is allowed to install — minimum release age, lockfile policy, registry
pinning — across the config files on this machine. Your job is to run the scan,
stop if it passes, and fix what it reports if it does not.

**This issue is filed unconditionally, every Monday, WITHOUT anyone having
scanned first.** It is not evidence that anything is failing. Run the scan
before you form any view of what is wrong.

## 1. Scan first — and stop here if it passes

    dev depsguard

Its verdict is its exit code — the same contract every producer check uses:

| Exit | Means | Do |
|---|---|---|
| 0 | every check passes | **dismiss and stop**, below |
| 1 | real failures, one line each on stdout | section 2 |
| 2 | the scan itself could not run | section 3 |

Read the output, not just the code: a positive `All depsguard checks pass` line
is the pass signal, not the absence of an error.

A passing week is a **successful run**:

    dev issues status <n> --status dismissed --comment "dev depsguard exited 0 — all supply-chain config checks pass. Nothing to fix."

Then stop. Do not open a PR and do not go looking for other work.

`dismissed` and not `fixed` deliberately: a no-op run must leave a TERMINAL
issue. `fixed` and `deployed` are both non-terminal for producer dedup, so
closing this `fixed` would suppress next Monday's scan, and the one after, until
someone clicked verify.

The scan reads config on THIS machine — `~/.npmrc`, `~/.bunfig.toml`,
`~/.yarnrc.yml`, `~/.config/uv/uv.toml` — which is why it runs here, in the same
session that will do the fixing, rather than on a server. Its verdict describes
the box it ran on.

## 2. Failures — fix them

One class of failure is already filtered out and will never appear: pnpm's
`minimum-release-age` reported "not set" on an npm-only repo (one with a
`package-lock.json` and no `pnpm-lock.yaml`). Those repos are deliberately
npm-only, the key is meaningless there, and a previous auto-fixer that kept
adding it produced endless add/revert churn on `apibuilder-ui`'s `.npmrc`.
**Never add `minimum-release-age` to an npm-only repo**, whatever a failure line
seems to ask for.

1. Fix each failure by editing the config file named in its bracket. These are
   usually machine-global files under `$HOME`, and sometimes a specific repo's
   `.npmrc`.
2. Re-run `dev depsguard` and confirm it now exits 0, with the
   `All depsguard checks pass` line.
3. A change to a file under `$HOME` is not in any repo and just gets made. If a
   repo's `.npmrc` needs a change, that repo gets a normal branch + PR per
   CLAUDE.md — never a commit straight to its main:

       gh pr create --draft --title "ISS-<n>: <what changed> (<repo>)"
       gh pr ready <pr>

## 3. When it cannot be fixed

If a failure needs a decision (dropping a package, changing a policy, a tool
that is not installed), do not guess. Say what needs deciding and close this
issue `--status needs_input` with that question. A config check that stays red
on purpose is fine as long as somebody chose it.

Exit 2 is the same kind of answer: the scan could not run, so nothing was
concluded. Report the error here, and close `--status needs_input` if clearing
it needs a decision.

## Closing out

- Config files under `$HOME` changed, nothing to PR → `dev issues status <n>
  --status fixed --url "<this issue's URL>"`, describing what changed in the
  comment.
- A repo change → close with the PR's URL.
