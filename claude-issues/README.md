# claude-issues prompt content

One `<category>-body.md` per `issue_category` in the platform `issues` spec — the durable
orientation (pipeline map, decoding guide, working rules) for fixing that category's issues:

| file               | category   | orients the session to                                    |
| ------------------ | ---------- | --------------------------------------------------------- |
| `graphs-body.md`   | `graphs`   | the native graph dashboards in clubaid-app                |
| `worker-body.md`   | `worker`   | the async workers — chiefly the Court Reserve pipeline    |
| `insights-body.md` | `insights` | insight-generation quality (playbook + clubaid-admin)     |

Each is read by **`dev issues claim --category <category>`** (`bin/dev`), which claims that
category's open issues and appends the matching body to the plan it writes under
`~/code/claude/plans/<date>-issues-<category>.md`. Edit the prose here; the command picks it up
automatically. One session per category — which is why the bodies do not overlap.

Adding a category means all three: the `issue_category` enum in the platform `issues` spec,
`ISSUE_CATEGORIES` in `bin/dev`, and a `<category>-body.md` here (the claim fails on the
missing file otherwise).

The issue tracker replaces Linear and the old playbook-feedback queue (`dev feedback`, removed
along with its API). `worker` issues are auto-filed by the daily log review; `insights` issues
are captured in-app when an admin reviews an insight or rejects a proposed checklist item; the
rest are filed by hand or captured in-app.
