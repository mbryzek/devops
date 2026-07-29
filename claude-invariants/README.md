# claude-invariants prompt content

The durable orientation `dev invariants check` hands to a Claude session when it offers to
investigate a failing invariant:

| file                     | used for                                            |
| ------------------------ | --------------------------------------------------- |
| `investigate-body.md`    | every failing app — how to classify and work the failure |

`bin/dev` renders only the app-specific part of the prompt (which app, and that app's failure
block exactly as the terminal printed it) and appends this file verbatim. Edit the prose here —
the command picks it up automatically, no code change needed.

It is deliberately generic: nothing here names an invariant, a table, or a pipeline, because the
command cannot know which invariant will fail. Anything specific to ONE pipeline belongs in that
pipeline's issue body under `../claude-issues/`, not here.

One session is launched per app with failures. When two or more apps fail at once a single
session fans out one subagent per app — `dev` can only hand the terminal to one process, so the
per-app parallelism moves inside it (same shape as `dev issues claim`).
