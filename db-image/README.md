# Session-DB images

Every Scala project's schema repo (`platform-postgresql`, `acumen-postgresql`,
…) produces the same thing: a Postgres image with that project's schema baked
in, plus a `<database>_template` clone that `claude-db` copies once per Claude
session, so parallel sessions never share a database and Mike's Postgres.app on
`:5432` is never touched.

```
registry.digitalocean.com/bryzek/<database>:<schema-git-tag>
```

This directory is the **recipe** — the Dockerfile, the init script, the
ownership transfer. It is app-agnostic. The **artifacts** (baseline schema,
seed, SEM tracking, journal settings) live in each schema repo under `docker/`.
`bin/db-image` stages the two together into a build context, because `COPY`
cannot reach outside the context and they live in different repositories.

Nothing about a specific app appears in this directory or in `bin/db-image`:

| Fact | Where it comes from |
|---|---|
| database name, owning role | the devops config that already describes them — `dist/<app>.config.json` → `scala.development.database` |
| image name | the database name |
| container / template / session-DB names | derived from the database name (`DbApp`) |
| baseline tag | `<repo>/docker/baseline-tag` — it moves with that repo |
| which apps exist | apps with a `scala` config and a `~/code/<app>-postgresql` checkout |

Adding a Scala project therefore requires no change here: give it a database
config and a schema repo, cut a baseline, and it appears in `claude-db`,
`verify-db-images` and `release-db`.

---

## Commands

```
db-image build [--app APP] [--tag TAG] [--push] [--repo-dir DIR]
    Build registry.digitalocean.com/bryzek/<database>:<tag>.
    Default tag: the repo's latest released schema tag.
    Without --push: local, native arch. With --push: multi-arch
    (linux/amd64,linux/arm64) via a docker-container buildx builder.

db-image baseline [--app APP] [--snapshot FILE] [--keep-data TABLE]... [--repo-dir DIR]
    Re-cut the committed baseline from a production snapshot.
```

`--app` is inferred from the directory, the way every other devops command
infers it, so from a schema repo both commands are bare:

```bash
cd ~/code/platform-postgresql
db-image build            # == --app platform --repo-dir .
```

A directory that names an app supplies the app (`platform-postgresql`,
`platform`, and feature clones of either under `~/code/ai`); a directory that
*is* that app's schema repo also supplies the checkout, so a build run inside a
feature clone builds that clone rather than silently reaching for Mike's
`~/code` one. `--app` naming a different app than the directory does not adopt
the directory's checkout. Every run prints the app, the database and the repo it
resolved to, so an inference is never silent.

```
claude-db next-port                        a free host port (5500-9999)
claude-db start --app APP [--port N]       this session's database; prints CONF_DB_DEV_URL
claude-db sync --app APP [--repo-dir DIR]  apply the migrations it is missing
claude-db end [--app APP]                  drop it (all apps by default)
claude-db status [--app APP]               containers, tags, ports, session databases
claude-db gc [--app APP] [--days N]        reap session databases older than N days (default 3)
                         [--apply]         and the containers left holding none; dry-run without --apply

verify-db-images [--app APP] [--dry-run]   audit the registry; build+push if the latest tag is missing
```

Among the `claude-db` commands `--app` is required only for `start`: creating a
database means choosing which app's schema it holds, and being in some
directory is not that choice. The read-only and reclaiming commands default to
every app, so a single `claude-db end` cleans up after a session that used more
than one.

---

## How a build works

At the **baseline tag**, the committed `docker/baseline-schema.sql`,
`sem-tracking.sql` and (if present) `baseline-journal-settings.sql` are baked
directly.

At any **later tag**, `db-image` spins a scratch `postgres:18` on an ephemeral
port, applies the baseline plus its tracking and journal rows, transfers
ownership to the app role, then runs `sem-apply` for only the scripts added
between the baseline and the target tag — `sem-apply` rather than raw `psql`, so
the tracking rows are recorded exactly as a real database would record them. The
result is dumped and baked.

`docker/seed.sql` is baked as-is either way. It is **hand-curated, never
generated**: the image is pushed to a shared registry and cloned into every
session, so no production row may ever reach it.

On first container start the init script creates the role and database, applies
schema → seed → SEM tracking → journal settings, transfers ownership of every
application object to the role (ownership, not `GRANT ALL` — migrations issue
`ALTER`/`DROP`/`CREATE TABLE`, which require it), and clones the database into
`<database>_template`.

---

## Cutting a baseline

```bash
db-image baseline --app acumen        # snapshot defaults to ~/Downloads/acumendb.sql
```

The baseline is cut from a **production snapshot**, not by replaying scripts
from empty. The image is then what production *is*, and drift shows up as a diff
rather than hiding inside a reconstruction.

1. Scratch `postgres:18` on an ephemeral 127.0.0.1 port.
2. Role and database created by running the schema repo's own `install.sh`
   (its `psql ` lines) against that container.
3. The snapshot is streamed in with **every COPY block dropped** except
   `schema_evolution_manager.{scripts,bootstrap_scripts}` and `journal.settings`
   — data rows that are really *schema state*. Without the SEM rows, `sem-apply`
   would replay the entire script history against an already-full schema.
   Production data is dropped as the file streams, so it never lands anywhere.
4. `sem-apply` brings the snapshot up to `sem-info tag latest`; that tag is
   written to `docker/baseline-tag`.
5. Ownership transfer, then `pg_dump` of the schema, the SEM tracking rows, and
   `journal.settings` when the app has a journal schema.

`bin/db-reinstall` is deliberately not reused for this: it drops Mike's local
database on `:5432`. Everything above happens in a throwaway container.

### `--keep-data`, and why it needs an FK-closed set

`--keep-data schema.table` additionally loads one table's rows and dumps them to
a temp directory, for authoring `docker/seed.sql` by hand. Those are **production
rows** — synthesize anything personal before committing, and delete the dump.

Whatever you keep has to bring along everything it points at. A `pg_dump` file is
ordered in three parts:

1. `CREATE TABLE …` — the tables, with no foreign keys yet
2. `COPY … FROM stdin` — one block of rows per table
3. `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY …` — the constraints, at the end

Step 3 is where a partial keep-list breaks. `ADD CONSTRAINT` **validates the rows
already in the table**, so keeping `public.users` while dropping `storage.files`
fails when the FK is added: the kept users reference avatar files that were never
loaded. Production is perfectly consistent — the subset is not.

`session_replication_role = replica` (which the loader sets) does **not** help
here, and it is worth being precise about why. That setting disables *triggers*,
and FK enforcement during INSERT/UPDATE/COPY is implemented as triggers — so it
does suppress checks while data is loading, which is why keeping tables works at
all. But the validation inside `ADD CONSTRAINT` is a one-shot scan performed by
the DDL itself, not a trigger, so nothing suppresses it.

So a keep-list must be **FK-closed**: every table it names, plus everything those
rows reference, transitively. The failure tells you exactly what is missing —
the error names the constraint and the absent referenced table — so add that
table and re-run, or drop the one that references it. (`bin/db-filter-dump`'s
allow-list policy carries the same requirement, for the same reason.)

---

## Image tag = schema tag

The image tag is the schema (git) tag, unmodified.

**Known regression, accepted deliberately.** The image is schema PLUS **recipe**
— this directory and the schema repo's `seed.sql` — and the recipe can change
without a schema release. With a bare tag, the registry and every local Docker
cache already hold an image for that tag, so a **recipe-only change reaches
nobody until the next schema tag bump**. (That is how a template once kept
seeding null `contact_email`s long after the seed was written to fix it.)

This used to be solved by hashing the recipe into the tag (`<schema-tag>-r<hash>`).
That is gone: `claude-db` runs **one container per schema tag**, and a tag that
moved without a schema release meant tearing down the shared container — which
destroyed every other Claude session's database. One `claude-db start` was
measured wiping four other sessions' databases.

**Mitigation is discipline: bump the schema tag when you change the recipe.**

When the recipe change is a **fix to a broken image** there is nothing to bump —
the already-pushed tag is the broken one. Rebuild and push each app's current
tag over it, then throw away the stale local copies, or every machine keeps
serving the broken image out of its Docker cache:

```
db-image build --app platform --tag $(cd ~/code/platform-postgresql && sem-info tag latest) --push
db-image build --app acumen   --tag $(cd ~/code/acumen-postgresql   && sem-info tag latest) --push
docker rmi registry.digitalocean.com/bryzek/<database>:<tag>   # on every machine that pulled it
```

Note this heals only the current tag. Older tags stay broken, which is fine —
retention purges images older than 3 days, and `claude-db` starts on latest.

---

## Ports

| Port | What | Who touches it |
|------|------|----------------|
| **5432** | Mike's Postgres.app (dev server, manual psql) | Mike only |
| **5500–9999** | Docker containers `<database>-claude-<schema-tag>` | Claude sessions only |
| ephemeral | scratch build containers, on 127.0.0.1 | `db-image` only |

There is no fixed port. Each container gets one, allocated by
`claude-db next-port` and recorded in `~/code/ai/.claude-db-ports.json`. Never
hardcode a port — use the `CONF_DB_DEV_URL` that `claude-db start` printed.

Everything talks to `127.0.0.1`, never `localhost`: scratch containers publish
on 127.0.0.1 only, and `localhost` resolves to `::1` first on this machine —
`sem-apply` once died mid-build on "connection to server at localhost (::1) …
Connection refused" while plain `psql` happened to fall back to IPv4.

A legacy untagged `platformdb-claude` container may still be running from before
the per-tag split. `claude-db status` lists it and `gc` reaps it once it holds no
session databases; nothing removes it by force.

---

## Connection limit

`claude-db start` runs each container with `-c max_connections=300`. One
container serves every session on a schema tag, and one session's Play app opens
up to `hikaricp.maximumPoolSize = 50`, so Postgres's stock 100 is exhausted by
two concurrent sessions — the third gets `sorry, too many clients already`, which
reads as a broken branch rather than as a full container.

It is set on `docker run` because `max_connections` is a postmaster GUC: `ALTER
SYSTEM` needs a full restart (a reload does nothing), and a new schema tag builds
a new container from the image and is back to 100 anyway. **Containers created
before this landed keep their old limit** — `claude-db gc` reaps one once it
holds no session databases, and the next `start` recreates it correctly sized.

---

## Routing: CONF_DB_DEV_URL

Each app's `conf/devtest.conf` reads it:

```hocon
db.default.url = "jdbc:postgresql://localhost/<database>"
db.default.url = ${?CONF_DB_DEV_URL}
```

The production URL lives in a separate variable, `CONF_DB_PROD_URL` (read only
by `application.conf`), so dev/test config never names it and cannot reach the
production database. `CONF_DB_DEV_URL` is additionally asserted at startup to
target localhost/127.0.0.1.

Both apps read the *same* variable, so export it in the same shell call as the
`sbt` run it is for — environment does not persist between calls anyway.

### Forgetting it used to be silent

Nothing about that fallback fails. A session that never exported
`CONF_DB_DEV_URL` just writes to Postgres.app, and the only symptom is stale-data
failures that read as code bugs — a 247-failure platform run on 2026-08-04
(ISS-318) that was green, on the same commit, against a session database.

`bin/run` now refuses instead. Before it hands anything to sbt it calls
`bin/assert-session-db`, which blocks a `test`/`run` task when `CLAUDECODE` is
set and `CONF_DB_DEV_URL` is either unset or resolves to `:5432`, and prints the
`claude-db start` line to fix it. The refusal costs nothing — it happens before
the compile.

It keys on the **caller**, not the port: `:5432` is Mike's database on purpose,
so an interactive run sees no check, no prompt and nothing to opt out of. Tasks
that open no database (`compile`, `scalafmt`, a bare `set …`) are never gated,
in either case. platform's own startup check (`core.util.DbLocalUrlChecker`) is
still there as the backstop for anything reaching sbt without going through
`run.sh`.

---

## Self-heal and retention

`verify-db-images` audits each app's latest schema tag and builds+pushes it if
missing. `DbImages.purge_old(app)` deletes registry images older than 3 days
while always retaining that app's current tag and its baseline anchor; it
refuses to purge at all when the latest tag cannot be determined.

`release-db` runs both after a successful schema migration, for any app that has
a `docker/baseline-tag`. Both steps are best-effort: the schema is already
deployed at that point, so a failure warns (with the exact manual command) and
does not fail the release.

---

## The template is always behind main — `claude-db sync`

The image tag is the latest **released** schema tag, so the template holds the
schema as of that release. Every migration merged to main since is missing from a
brand-new session database, and recreating it does not help: `end` + `start`
clone the SAME stale template. A branch that adds its own migration is behind by
that too.

Nothing about this announces itself. The suite fails as though the branch were
broken — `relation "playbook.person_members" does not exist` for a table main
added, `null value in column "auto_classification" violates not-null` for a
column main **dropped**. Both read as a code defect, and the second one is worse
than the first: the table is there and looks fine. That cost two hours on
2026-08-03 (ISS-276), on a branch that was in fact green.

**You do not have to notice this.** The platform suite refuses to start against a
drifted session database (`core.util.SchemaDrift`, run from the same startup
check that already validates `CONF_DB_DEV_URL`), and prints the missing scripts
and the one command that applies them. That is the trigger; `sync` is the fix.
Syncing on `start` alone was not enough — the expensive case is a branch that
rebases onto a schema change *mid-session*, long after `start` ran.

`claude-db start` closes the gap on its own, and `claude-db sync` re-closes it
after a rebase:

```bash
claude-db sync --app platform
claude-db sync --app platform --repo-dir ~/code/ai/<feature>/platform-postgresql
```

The delta is applied with **`sem-apply`, not generated DDL**. That is what makes
it correct rather than merely convenient: these are the same scripts in the same
order production ran, so DROPs and FK ordering come out right; sem-apply connects
AS the app role to a role-owned database, so new tables are owned by `api` rather
than `postgres` (hand-applied DDL leaves every table it creates permission-denied
to the app, which is a false-failure mode of its own); and the tracking rows land,
so the next sync knows what this one did.

**Two gaps, not one.** Syncing matches the database to the **checkout**, and the
checkout can itself be behind `origin/main` — measured at 3 commits on the day
this was written, which would have left the database 3 migrations short while
reporting "up to date". `sync` fetches the checkout's `origin` first and warns
when it sees that, naming the fresh-clone escape hatch. It fetches because the
count is read from `refs/remotes/origin/main`: an unfetched checkout does not
report a hedged number, it reports **zero**, and a warning that can silently read
green is worse than no warning. Fetching touches remote refs only — never the
working tree, never a local branch. When the fetch fails (offline) the number is
reported as a floor.

**Which checkout.** Nearest first: the cwd if it is the schema repo, then a clone
of it beside the cwd (`~/code/ai/<feature>/platform-postgresql` when you are in
`~/code/ai/<feature>/platform`), then `~/code/<app>-postgresql`. A session that
has its own clone means to use it — reaching past it to `~/code` is how a branch
carrying its own migration gets synced to main and silently does not get it.

`claude-db status` states the same drift per database (`3 MIGRATION(S) BEHIND`),
so it is visible without running anything.

A database whose `schema_evolution_manager.scripts` table is missing or
unreadable is an **error**, never "nothing applied" — that reading would replay
the entire 800-script history against a full schema.

## Migration authoring in a session DB

`sem-apply` against a session database applies only scripts not already recorded
in `schema_evolution_manager.scripts` — tracking is baked into the image, so it
does not replay from scratch. Use the port from the `CONF_DB_DEV_URL` that
`claude-db start` printed:

```bash
# from the schema repo checkout — dev.rb forwards --url to sem-apply
./dev.rb --url "postgresql://api@localhost:<port>/<database>_sess_<id>"
```

Session databases are cloned `OWNER api`, so migrations issuing `CREATE SCHEMA` /
`ALTER TABLE` run without superuser. Bare `./dev.rb` targets Mike's `:5432`
database — always pass `--url` in a session.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker: Cannot connect to the Docker daemon` | Docker Desktop not running | Start Docker Desktop |
| `doctl registry login` fails | Not authenticated | `doctl auth init` |
| Image missing for the current tag | Schema released before the image was pushed | `verify-db-images` (self-heals) |
| Schema tag advanced and my session DB is "missing" | Each tag has its OWN container; the database still lives in the container for the tag you started on | Nothing is lost — `claude-db status` shows which container holds it |
| `claude-db start` says a port is required | No container exists yet for this app + schema tag | `claude-db start --app APP --port "$(claude-db next-port)"` |
| Recipe change not showing up | The image tag is the bare schema tag, so the cached image is reused | Bump the schema tag — see "Image tag = schema tag" |
| `<database>_sess_*` databases accumulating | Sessions ended without `claude-db end` | `claude-db gc` to preview, `claude-db gc --apply` to reap |
| A wall of `relation "x" does not exist`, or a not-null violation on a column main dropped | The session DB predates migrations that are on main — the template is the last RELEASE | `claude-db sync --app APP` (see above). `claude-db status` shows the count |
| `sync` says "up to date" but the suite still fails on a missing relation | The checkout is behind `origin/main`; sync matched the DB to it | Pull the checkout, or `sync --repo-dir <fresh clone>` |
| `db-image baseline` cannot find a snapshot | No recent production backup downloaded | Put one at `~/Downloads/<database>.sql` or pass `--snapshot` |
