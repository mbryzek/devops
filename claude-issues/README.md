# claude-issues prompt content

The durable orientation appended to every issue plan `bin/dev` writes — the pipeline map,
decoding guide, and working rules a fix session needs:

| file                 | used for                        | orients the session to                                 |
| -------------------- | -------------------------------- | ------------------------------------------------------ |
| `graphs-body.md`     | category `graphs`               | the native graph dashboards in playbook-app             |
| `worker-body.md`     | category `worker`               | the async workers — chiefly the Court Reserve pipeline  |
| `insights-body.md`   | category `insights`             | insight-generation quality (playbook + playbook-admin)  |
| `club_backfill-body.md` | category `club_backfill`     | a club's initial history load held short of completion  |
| `suggestion-body.md` | category `suggestion`           | investigating a member's request, not building it       |
| `default-body.md`    | every other category            | triaging the issue, then the shared working rules       |
| `manual-body.md`     | `dev issues create` (prepended) | what is specific to a hand-filed issue                  |
| `review-summary.md`  | `dev issues review`             | summarising ONE blocked issue for the human answering it |

`review-summary.md` is the odd one out and it is worth saying why. Every other file here
orients a session that is about to DO the work. That one orients a session that must not:
it reads an issue sitting at `needs_input`/`needs_review` and writes the compact "here is
what you are actually being asked" that `dev issues review` prints to Mike a second before
he types his answer. It runs with Edit, Write, NotebookEdit and Bash denied at the CLI, so
it can read every repo under `~/code` and change none of them — see `lib/issue_review.rb`.
Its one instruction that carries the whole feature is *read the code the issue references*:
the question was recorded by a session that had that context and the person answering does
not, which is the friction the command exists to remove.

**`dev issues claim`** claims a category's open issues and writes **one plan per issue** under
`~/code/claude/plans/<date>-issue-<number>-<slug>.md`, appending `<category>-body.md` to each.
Categories with their own pipeline get their own file; every other category falls back to
`default-body.md`. Edit the prose here — the command picks it up automatically.

One plan is one issue because a plan is the unit a subagent gets handed, so it has to be a unit
of work. Grouping is the spawned session's call, not the CLI's: it reads the plans and gives two
in the SAME category that touch the same feature to one subagent, so their fixes land on one
branch instead of colliding in the same files. That judgment needs the code read, and the CLI has
only a title and a category. Never across categories — those are independent pipelines and repos.
A bundled subagent still closes each of its issues with `dev issues status`, all pointing at the
same PR URL, since `dev issues reconcile` can only adopt the one named in the PR title.

Per-issue context is rendered by `bin/dev`, not from these files: each claimed issue carries its
previous fix PRs and its full comment history into the plan, and a RE-OPENED issue leads with a
banner saying the earlier attempt did not hold and to work it in a NEW `~/code/ai/` directory and
branch. An issue that went from `needs_input`/`needs_review` back to `open` leads with the
opposite banner instead — a human ANSWERED it, quoted in full — because that is a human
unblocking the issue, not a fix that failed (ISS-989). Edit that wording in
`issue_reopen_callout` / `issue_answer_callout` / `issue_render_item`, not here.

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

The issue tracker is the single system of record for this work — there is no external tracker.
It replaced the old playbook-feedback queue (`dev feedback`, removed along with its API), which
was the last thing it superseded. `worker` issues are auto-filed by the daily log review; `insights` issues
are captured in-app when an admin reviews an insight or rejects a proposed checklist item;
`suggestion` issues are submitted by club members in playbook-app; `club_backfill` issues are auto-filed
by the club history backfill driver when it refuses to stamp completion; the rest are filed by hand.
