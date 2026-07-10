# claude-feedback-fix — hourly graph-feedback fix job

Closes the loop for graph feedback (platform PR #1328, clubaid-app PR #124): an admin
comments on charts at app.clubaid.co/graphs/*; comments land in the `feedback` schema;
this job claims them (server-side atomic claim, 1h quiet window) and runs a headless
Claude session that fixes them and opens PRs.

For a manual, non-automated alternative, `dev feedback claim` does the same claim but
writes a plan to `~/code/claude/plans/` for you to hand to an interactive session; it
reuses `graph-feedback-body.md` and closes items via `dev feedback status`.

## Pieces

- `bin/claude-feedback-fix` — login → claim → hand claimed JSON to `claude --print`
  with `claude-feedback/prompt.md`. Exits quietly when the queue is empty or a review
  session is still in flight. Logs to `~/code/claude/logs/claude-feedback-fix.log`.
- `claude-feedback/prompt.md` — the headless-specific wrapper (env inputs +
  status-update curl), researched per `rules/llm.ticket.prompts.mdc`.
- `claude-feedback/graph-feedback-body.md` — the durable orientation (pipeline
  map, decoding guide, working rules), shared verbatim with `dev feedback claim`
  so the two never drift. The job runs `cat prompt.md graph-feedback-body.md`.
- `claude-feedback/com.bryzek.claude-feedback-fix.plist` — launchd template (hourly).

## Setup (one-time, deliberate — this schedules an autonomous token-spending job)

1. Credentials: add an admin login for the job to `~/code/env` and export
   `CLUBAID_FEEDBACK_EMAIL` / `CLUBAID_FEEDBACK_PASSWORD` in the plist (or your shell
   for manual runs).
2. Install the schedule:
   ```bash
   cp ~/code/devops/claude-feedback/com.bryzek.claude-feedback-fix.plist ~/Library/LaunchAgents/
   # edit the EnvironmentVariables block with the real credentials first
   launchctl load ~/Library/LaunchAgents/com.bryzek.claude-feedback-fix.plist
   ```
3. Manual run (uses your shell env): `~/code/devops/bin/claude-feedback-fix`

## Removing the feature

Drop the `feedback` schema, delete `spec/playbook-feedback.json` +
`dao/spec/db-feedback.json` + the clubaid-app capture UI, `launchctl unload` the plist,
and delete this directory.
