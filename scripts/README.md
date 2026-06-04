# Utility scripts

One home for ad-hoc developer/operations scripts, surfaced through the `dev` CLI:

```
dev scripts list                    # every script here, with allowed targets + description
dev scripts run <name>              # run against the LOCAL platformdb (default)
dev scripts run <name> --prod       # run against production (if the script allows it)
dev scripts run <name> --env development
```

Adding a script = drop a file here. No `dev` CLI changes required.

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

- **Local `.sql`** → `psql -U api -f <file> platformdb` with `ON_ERROR_STOP=1`.
  The runner refuses if `PGHOST` points at a non-local host, so a stray env var
  can't redirect a local script at production. Wrap multi-statement SQL in
  `begin; ... commit;` so a failure rolls back cleanly.
- **Production / development `.sql`** → delegated to `db exec`, which tunnels
  through the bastion. Production runs prompt for typed confirmation first.
- **Executable files** (shell/Ruby with a shebang + executable bit) → exec'd
  directly, local only; args after `--` are passed through.
