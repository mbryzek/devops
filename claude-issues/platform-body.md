## How this pipeline works

- **Backend**: repo `mbryzek/platform` — a Scala 3 / Play monolith with one subproject per
  domain (`core/`, `dao/`, `integrations/`, `clubaid/`, `playbook/`, `hoa/`, `rallyd/`, ...),
  PostgreSQL underneath. Dependency direction is one-way: playbook → clubaid → integrations →
  core; nothing points back.
- **Contract**: every endpoint is defined in an API Builder spec under `platform/spec/` and
  generated on both sides. Changing a spec is a CROSS-REPO change — the frontends regenerate
  their own clients from the registry, so find and fix every consumer on the same branch.
- **Schema**: tables are generated from the DAO specs (`platform/dao/spec/*.json` →
  `platform/dao/psql/*.sql`) via `api --group dao`; migrations live in `platform-postgresql`.
  NEVER hand-write `CREATE TABLE` / `ALTER TABLE` for a new table — it skips audit columns,
  `hash_code`, and journal triggers.
- **Async work** runs through task processors; the periodic actors schedule them.

## Decoding the issue

- The **title** is the one-line report; the **body** carries the detail — for auto-filed issues,
  the evidence (log lines, error text) and often an AI fix prompt naming the code paths. Start
  there.
- **`occurrence_count` > 1 means it recurs** (the tracker dedups on `fingerprint`, bumping the
  count and adding a timeline comment). Treat a high count as ongoing breakage and fix the root
  cause, not the symptom.
- **Get the real error before hypothesizing.** Production logs / New Relic are the source of
  truth for a prod fault; local session DBs are schema-only (no prod rows) and you must NEVER
  touch the production DB. Reproduce with a fixture built from the evidence.
- **Club** (when present) is the tenant context the report came from.

## Working rules (from ~/code/CLAUDE.md — read it)

1. Read `~/code/CLAUDE.md` and the relevant `~/code/claude/rules/*.mdc` files first
   (especially `scala.general.mdc`, `scala.daos.mdc`, `scala.test.helpers.mdc`,
   `database.general.mdc`, and `apibuilder.general.mdc` if the contract changes).
2. Work in a feature dir under `~/code/ai/` (branch name ≤ 19 chars, e.g. `iss-plat-<date>`);
   clone `platform` (plus `platform-postgresql` and any consumer repo the change touches).
   Never edit `~/code/platform` directly.
3. Group related issues into one branch/PR — one root cause, one fix.
4. Verify: a scoped `sbt` spec that FAILS without your fix. Run against the isolated Docker
   session DB (`eval "$(~/code/devops/bin/claude-db start | grep '^CONF_DB_DEV_URL=' | sed
   's/^/export /')"`), never Mike's `:5432` and never production. Any API Builder spec change
   needs explicit approval on the exact JSON before you implement it.
5. Commit, push, open a DRAFT PR (`gh pr create --draft`), then mark it ready
   (`gh pr ready`), then rebase onto latest origin/main + rerun codegen per the standard
   done-workflow.
6. Progress reporting for long runs: `openclaw system event --text "Progress: ..." --mode now`
   every ~15 minutes.
