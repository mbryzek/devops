# api lint cleanup: {child}

Run `api lint` in **{child}** and open a PR if it rewrote a spec. ONE repo, ONE
PR. The sibling children of this epic own the other spec-owning repos — do not
clone them, do not lint them, and do not open a PR against them.

The linter is mechanical: it removes imports a spec declares and never
references, and it normalizes the spec JSON. Your job is the part a script could
not do — read what it changed and decide whether it is right.

## Doing it

Work inside the workspace directory this session was given
(`~/code/ai/<slug>/`). Never lint a checkout under `~/code/{child}` — that is
Mike's working tree.

1. `gh repo clone mbryzek/{child} <workspace>/{child}`. A FULL clone — never
   `--depth`, which cannot be rebased or pushed from reliably.
2. Run `api lint` in the clone. No sibling `devops` symlink is needed: `{child}`'s
   `.api/config.pkl` amends `modulepath:/api/ApiConfig.pkl`, which `api` resolves
   against the devops checkout the CLI itself runs from (ApiConfig::BASE_MODULE_URI),
   not against whatever happens to sit next to the clone.
3. `git status --porcelain`. Nothing changed → {child} is clean, say so and close
   out. That is a successful run.
4. Something changed → **read the diff**. Confirm the rewrite is only
   unused-import removal and formatting, and that no resource, model, enum,
   field or still-referenced import was dropped. If the linter removed an import
   a spec actually uses, that is a FINDING to report on this issue, not a PR to
   open.
5. Commit on this session's assigned branch, push, and open the PR with
   `gh pr create --draft --title "ISS-<this issue>: api lint cleanup ({child})"`,
   then `gh pr ready <pr>`. No `--base` — it defaults to main, and passing it is
   how stacked PRs happen.

If `api lint` itself fails in {child}, that is the finding: capture the error,
report it here, and do not open a PR.

## Report and close out

Say what happened to {child} — clean, PR URL, or the error — then:

    dev issues status <n> --status fixed --url "<PR URL>"

A week where {child} is clean is a successful run, not a failure: close it
`fixed` with a comment saying no drift was found and no PR was needed. Do NOT
mark this issue `verified` — its epic is what gets verified.
