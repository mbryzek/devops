# Weekly api lint cleanup

This is a CONTAINER, not a unit of work. Nothing is claimed here and nothing is
linted here: each child issue is ONE spec-owning repo's lint run, worked in its
own workspace, on its own branch, with its own PR.

`api lint` itself is mechanical — it removes imports a spec declares and never
references, and it rewrites the spec JSON in place. The judgment is in reading
what it rewrote, and that is why this is a claimed session rather than a cron:
a linter that dropped an import a spec still uses is a FINDING, not a PR.

## Why an epic

The week is N independent runs — N clones, N lints, N PRs. As one issue they
shared one lease and one 4-hour budget, so a single wedged repo took the whole
run with it and a failure in the fourth repo hid the first three. As children
each repo gets its own lease, its own retry, its own budget and its own visible
outcome.

A repo whose previous week's issue is still open — a lint PR nobody has merged
yet — is deliberately NOT re-filed; the rest still run. Before, that one open PR
held up the whole weekly producer.

## Which repos

`ApiLint::REPOS` in devops/lib/api_lint.rb, which is what `children.names` in
agent/producers.yml must equal — asserted by test/test_agent_cron_migration.rb,
so a spec-owning repo added to one list and not the other fails the suite
instead of silently never being linted.

`dependency` owns specs and is deliberately NOT a child: it never migrated off
the legacy `.apibuilder/config`, so `api lint` there exits immediately with "No
.api/config.pkl found". It is recorded in `ApiLint::UNSUPPORTED` with that
reason rather than dropped from the list.

## Verification

This epic advances to `deployed` on its own once every child is terminal, and it
is the single thing to verify for the week — verifying it verifies every child
with it. Review the PRs the children opened, then verify here.
