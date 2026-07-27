# Investigating this suggestion

A `suggestion` is a club member's product feedback, filed from playbook-app. Your job
is to INVESTIGATE it and hand it back with a recommendation. It is not a defect report
and it is not an approved piece of work.

**Do not create a branch. Do not write code. Do not open a PR.** No part of this is an
implementation session. If the answer is "this is a two-line change", say that in your
findings and stop — the decision to build it is not yours.

## What to produce

Read the issue, its attachments, and whatever code and data it concerns. Start with
`dev issues show <NNN>`: it prints this issue's full comment history and any previous
fix PRs. If it was investigated before, the earlier findings are there and a
recommendation that repeats them is worth nothing — and a RE-OPENED banner means the
earlier recommendation did not stand. Use the same command on any issue this one
references.

Then post ONE comment covering:

- **What they are actually asking for** — in your words, separating the symptom they
  described from the change they want.
- **What the code and data say** — the real behavior, named by file and by pipeline. If
  the suggestion rests on a misunderstanding, say so plainly and show what is true.
- **Recommendation** — worth doing or not, and why. Include the alternative you would
  pick instead if there is a better one.
- **Rough size** — which repos and pipelines a build would touch, and anything that
  makes it bigger than it looks.
- **What to ask the club**, if the blocker is information only they have. State the
  question; do not address it to them.

Finish with:

    dev issues status <NNN> --status needs_review --comment "<your findings>"

The issue number is POSITIONAL. There is no flag form for it — pass it as a bare
argument or the command exits with `unexpected argument(s)`.

If the suggestion concerns a pipeline with its own orientation, read that body file
under `~/code/devops/claude-issues/` first — `graphs-body.md`, `worker-body.md`,
`insights-body.md`.

**Everything you write on an issue is an INTERNAL note to the team.** It is never a
reply to the member who filed it, so do not address them ("Love this idea…", "Two
questions for you…") — write it to Mike. The server rejects a shared comment from an
automated actor, and nothing internal is ever quoted to the member. When the member
genuinely needs to be asked something, say plainly what should be asked; Mike writes and
shares the customer-facing reply from playbook-admin.

## How to work

Follow `~/code/CLAUDE.md`. For an investigation that means:

- You may clone repos into a NEW `~/code/ai/<short-name>` (≤19 chars) to read and run
  things. NEVER edit the checkouts under `~/code/` directly. Leave no commits behind.
- Read-only against the database. Never touch production data.
- If the brief is ambiguous, make the most reasonable reading, note the assumption in
  your findings, and keep going.
