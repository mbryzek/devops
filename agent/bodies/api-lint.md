# Weekly api lint cleanup

Run `api lint` across the spec-owning repos and open a PR wherever it rewrote a
spec. The linter is mechanical (it removes unused imports and normalizes spec
JSON); your job is to run it, read what it changed, and ship the changes that
are right.

## Repos

    platform  acumen  dependency  lib-ai

All four own apibuilder specs. Handle every one — a repo that is clean costs a
clone and a lint.

## Doing it

Work in ONE feature dir under `~/code/ai/<short-name>/` (≤19 chars) and clone
each repo into it. Never lint a checkout under `~/code/<repo>` — those are
Mike's working trees.

`api` is hermetic and resolves each repo's `.api/config.pkl`, which amends
`../../devops/api/ApiConfig.pkl` and therefore expects a sibling `devops` next
to the clone. Symlink one into the feature dir before linting:

    ln -sfn ~/code/devops <feature-dir>/devops

Then, per repo:

1. `git clone git@github.com:mbryzek/<repo>.git` into the feature dir. A FULL
   clone — never `--depth`, which cannot be rebased or pushed from reliably.
2. Run `api lint` in the clone.
3. `git status --porcelain`. Nothing changed → that repo is done, say so.
4. Something changed → **read the diff**. This is the part a script could not
   do: confirm the rewrite is only unused-import removal / formatting, and that
   no resource, model, enum, field or import something still references was
   dropped. If the linter removed an import a spec actually uses, that is a
   finding to report, not a PR to open.
5. Commit on a branch, push, and open the PR with
   `gh pr create --draft --title "ISS-<this issue>: api lint cleanup (<repo>)"`,
   then `gh pr ready <pr>`. No `--base` — it defaults to main, and passing it is
   how stacked PRs happen.

If `api lint` itself fails in a repo, that is the finding: capture the error,
keep going with the other repos, and report it.

## Report and close out

One line per repo (clean / PR URL / error), then:

    dev issues status <n> --status fixed --url "<the first PR URL>"

A week where all four repos are clean is a successful run, not a failure —
close it `fixed` with a comment saying no drift was found and no PR was needed.
