# graph-feedback prompt content

`graph-feedback-body.md` is the durable orientation (pipeline map, decoding guide,
working rules) for fixing graph-feedback items left on the ClubAid dashboards
(app.clubaid.co/feedback).

It is read by **`dev feedback claim`** (`bin/dev`), which claims open items and
appends this body to the plan it writes under `~/code/claude/plans/`. Edit the
prose here; the command picks it up automatically.

The former automated hourly job (`claude-feedback-fix` + launchd plist) was removed
— `dev feedback claim` is the manual replacement. See platform PR #1328 / clubaid-app
PR #124 for the feedback capture pipeline.
