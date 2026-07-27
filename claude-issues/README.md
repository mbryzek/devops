# claude-issues prompt content

The durable orientation appended to every issue plan `bin/dev` writes — the pipeline map,
decoding guide, and working rules a fix session needs:

| file                 | used for                        | orients the session to                                 |
| -------------------- | -------------------------------- | ------------------------------------------------------ |
| `graphs-body.md`     | category `graphs`               | the native graph dashboards in playbook-app             |
| `worker-body.md`     | category `worker`               | the async workers — chiefly the Court Reserve pipeline  |
| `insights-body.md`   | category `insights`             | insight-generation quality (playbook + playbook-admin)  |
| `suggestion-body.md` | category `suggestion`           | investigating a member's request, not building it       |
| `default-body.md`    | every other category            | triaging the issue, then the shared working rules       |
| `manual-body.md`     | `dev issues create` (prepended) | what is specific to a hand-filed issue                  |

**`dev issues claim`** claims a category's open issues and appends `<category>-body.md` to the
plan it writes under `~/code/claude/plans/<date>-issues-<category>.md`. Categories with their own
pipeline get their own file; every other category falls back to `default-body.md`. Edit the prose
here — the command picks it up automatically.

`default-body.md` holds the working rules ONCE. The pipeline bodies carry only what is specific
to their pipeline, and `manual-body.md` is prepended to `default-body.md` for a plan written by
`dev issues create`. `suggestion-body.md` is the one exception: it replaces `default-body.md`
outright rather than layering on it — an investigation runs under different rules (no branch, no
PR) than every other category's fix session, so it carries its own copy of the working rules it
still needs. Don't copy the working rules into another file otherwise.

Adding a category means the `issue_category` enum in the platform `issues` spec and
`ISSUE_CATEGORIES` in `bin/dev`. A `<category>-body.md` here is OPTIONAL — add one only when the
category has a pipeline of its own to explain; without it the claim uses `default-body.md`
instead of failing.

`dev issues claim` covers EVERY category by default, including `suggestion` and the manually
filed `feature`/`bug`/`improvement` — an open issue the CLI cannot reach is an open issue nobody
works. A claimed `suggestion` runs as an investigation rather than a fix: the session reads the
issue and the code, then hands back a recommendation with `dev issues status --status
needs_review`, instead of opening a PR.

The issue tracker replaces Linear and the old playbook-feedback queue (`dev feedback`, removed
along with its API). `worker` issues are auto-filed by the daily log review; `insights` issues
are captured in-app when an admin reviews an insight or rejects a proposed checklist item;
`suggestion` issues are submitted by club members in playbook-app; the rest are filed by hand.
