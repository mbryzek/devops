# claude-issues prompt content

One `<category>-body.md` per `issue_category` in the platform `issues` spec — the durable
orientation (pipeline map, decoding guide, working rules) for fixing that category's issues:

| file                    | category        | orients the session to                               |
| ----------------------- | --------------- | ---------------------------------------------------- |
| `graphs-body.md`        | `graphs`        | the native graph dashboards in clubaid-app           |
| `court_reserve-body.md` | `court_reserve` | the Court Reserve scrape → parse → coverage pipeline |
| `app-body.md`           | `app`           | clubaid-app outside the graphs                       |
| `admin-body.md`         | `admin`         | the clubaid-admin console (Elm)                      |
| `platform-body.md`      | `platform`      | backend/API behavior                                 |
| `infra-body.md`         | `infra`         | devops: k8s, deploys, alerting                       |

Each is read by **`dev issue claim --category <category>`** (`bin/dev`), which claims that
category's open issues and appends the matching body to the plan it writes under
`~/code/claude/plans/<date>-issues-<category>.md`. Edit the prose here; the command picks it up
automatically. One session per category — which is why the bodies do not overlap.

Adding a category means all three: the `issue_category` enum in the platform `issues` spec,
`ISSUE_CATEGORIES` in `bin/dev`, and a `<category>-body.md` here (the claim fails on the
missing file otherwise).

The issue tracker replaces Linear and the old playbook-feedback queue (`dev feedback`, removed
along with its API). `court_reserve` issues are auto-filed by the daily log review; the rest are
filed by hand or captured in-app.
