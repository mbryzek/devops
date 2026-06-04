# Utility scripts

One index for developer/operations scripts, surfaced through the `dev` CLI:

```
dev scripts list                    # every script here, with targets + description
dev scripts run <name> [args...]    # the name comes FIRST, then any arguments
```

Two kinds of scripts live here:

- **First-class scripts** — `.sql` files (and standalone executables) that *are*
  the utility. Example: `delete-test-uploads.sql`.
- **Wrappers** — thin executables that invoke a script living in another repo
  (it's coupled to that repo's helpers/config, so it stays there). Example:
  `clubaid-data-diff` wraps `platform/scripts/clubaid-data-diff.scala`. This lets
  `dev scripts list` index *every* utility without relocating coupled suites.

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
  is forwarded verbatim** (no `--` separator needed, and `--env`/`--prod` belong to
  the inner script, not the runner). A wrapper manages its own environment and
  confirms before production itself. Their `targets=local` just means "the wrapper
  runs on your machine" — see each wrapper's header for how to reach prod.
