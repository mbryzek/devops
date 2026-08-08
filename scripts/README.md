# Utility scripts

One index for developer/operations scripts, surfaced through the `dev` CLI:

```
dev scripts list                    # every script here, with targets + description
dev scripts run <name> [args...]    # the name comes FIRST, then any arguments
```

Two kinds of scripts live here:

- **First-class scripts** — `.sql` files (and standalone executables) that *are*
  the utility. Example: `truncate-court-reserve-data.sql`.
- **Wrappers** — thin executables that invoke a utility living somewhere else,
  because that is where it belongs: coupled to another repo's helpers/config
  (`rename-xlsx-period` wraps `misc/rename-xlsx-period.scala`), or behind an API
  (`delete-test-clubs` calls `POST /dev/local/test/club/deletions` on the local
  platform, which owns the club foreign-key order the SQL used to transcribe by
  hand). This lets `dev scripts list` index *every* utility without relocating
  coupled suites or keeping a second copy of somebody else's invariants here.

Adding a script (or wrapper) = drop a file here. No `dev` CLI changes required.

## The `dev-script:` header

Each script may declare a metadata line in its leading comments:

```
-- dev-script: targets=local,production app=platform
```

- **`targets`** (default `local`) — which environments the script may run against:
  `local`, `development`, `production`. `dev scripts run` refuses any target not
  listed here, so a destructive prod script must opt in explicitly.
- **`app`** — the app whose database `db exec` should target for non-local runs
  (required when `production` / `development` is allowed).

The first non-shebang, non-`dev-script:` comment line is the description shown by
`dev scripts list`. Use `-- ...` for SQL, `# ...` for shell/Ruby.

## How runs execute

The script **name is always the first token**; how the rest is handled depends on
the script type:

- **`.sql` scripts** — the remaining tokens are the runner's own env flags:
  - Local (default) → `psql -U api -f <file> platformdb` with `ON_ERROR_STOP=1`.
    The runner refuses if `PGHOST` points at a non-local host, so a stray env var
    can't redirect a local script at production. Wrap multi-statement SQL in
    `begin; ... commit;` so a failure rolls back cleanly.
  - `--prod` / `--env development` → delegated to `db exec` (bastion tunnel);
    production prompts for typed confirmation first. Allowed only if the env is in
    the script's `targets`. SQL scripts take no positional arguments.
- **Executable scripts / wrappers** — run locally; **every argument after the name
  is forwarded to the script** (an optional leading `--` separator is dropped, and
  `--env`/`--prod` belong to the inner script, not the runner). A wrapper owns its
  own environment — see its header for how it reaches prod and whether it prompts
  first: a wrapper that writes to prod is expected to confirm, a read-only one is
  not. Their `targets=local` just means "the wrapper runs on your machine."
