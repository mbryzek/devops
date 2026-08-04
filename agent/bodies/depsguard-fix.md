# Fix the failing supply-chain config checks

`dev depsguard` found real failures. The exact failing checks are in the evidence
block above — the scan's stdout, one line per failure with the config file it
came from in brackets.

One class of failure has already been filtered out and will never appear here:
pnpm's `minimum-release-age` reported "not set" on an npm-only repo (one with a
`package-lock.json` and no `pnpm-lock.yaml`). Those repos are deliberately
npm-only, the key is meaningless there, and a previous auto-fixer that kept
adding it produced endless add/revert churn on `apibuilder-ui`'s `.npmrc`.
**Never add `minimum-release-age` to an npm-only repo**, whatever a failure line
seems to ask for.

## What to do

1. Fix each failure by editing the config file named in its bracket. These are
   usually machine-global files rather than repo files — `~/.bunfig.toml`,
   `~/.yarnrc.yml`, `~/.config/uv/uv.toml`, `~/.npmrc` — and sometimes a specific
   repo's `.npmrc`.
2. Re-run `dev depsguard` and confirm it now exits 0. Read the output; a
   positive "All depsguard checks pass" line is the pass signal, not the absence
   of an error.
3. If a repo's `.npmrc` needs a change, that repo gets a normal branch + PR per
   CLAUDE.md — never a commit straight to its main. A change to a file in
   `$HOME` is not in any repo and just gets made.

## When it cannot be fixed

If a failure needs a decision (dropping a package, changing a policy, a tool that
is not installed), do not guess. Say what needs deciding and close this issue
`--status needs_input` with that question. A config check that stays red on
purpose is fine as long as somebody chose it.

## Closing out

- Config files under `$HOME` changed, nothing to PR → `dev issues status <n>
  --status fixed --url "<this issue's URL or the repo PR if there was one>"` and
  describe what changed in the comment.
- A repo change → open the PR per CLAUDE.md (draft, then ready, title prefixed
  `ISS-<n>:`) and close with its URL.
