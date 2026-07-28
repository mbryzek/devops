---
name: changelog-build
description: Turn raw per-release commit captures into curated, human-readable changelog notes. Invoked by `dev changelog build`.
---

# changelog-build

You are generating human-readable release notes for the playbook\* products. You are
running headless (`claude --print`) from a scratch directory. Every path you need —
this file, the input JSON, each `notes_file` — is absolute, so never resolve anything
relative to the working directory.

## Input

A JSON file whose path is given in your prompt. Shape:

```json
{
  "versions": [
    {
      "application": "playbook-admin",
      "version": "0.3.34",
      "released_at": "2026-07-22T14:00:00-04:00",
      "notes_file": "/abs/path/to/scratch/playbook-admin-0.3.34.notes.json",
      "commits": [
        { "sha": "…", "subject": "…", "body": "…", "pr_number": 412, "issue_number": "034" }
      ]
    }
  ]
}
```

`pr_number` / `issue_number` may be `null`. `issue_number` (when present) is the
in-house issue ISS-<number> already resolved for you — carry it through, do not guess.

## Task

`versions` usually holds **several** releases — the CLI batches them into one session.
Work through them one at a time and write each `notes_file` the moment you finish that
version, rather than holding all the output to the end: when your session ends the CLI
reads whatever files exist and posts them, so a session that dies partway still banks
every version you already wrote. Versions with no file are reported failed and retried
on the next run.

For **each** version, write its `notes_file` as JSON with this exact shape:

```json
{
  "application": "playbook-admin",
  "version": "0.3.34",
  "released_at": "2026-07-22T14:00:00-04:00",
  "entries": [
    { "summary": "Added a changelog page to the admin console.",
      "category": "feature", "pr_number": 412, "issue_number": "034" }
  ]
}
```

Carry `application`, `version`, `released_at` straight through from the input. The CLI
reads `entries`; the other keys are there so a file is readable on its own.

### Judge each commit — is it worth telling a human about?

**Keep** commits that change what a user or operator experiences: new features, bug
fixes, behavior/UX changes, performance or reliability improvements, notable API or
data changes.

**Drop** noise: version bumps, dependency/lockfile bumps, formatting/lint/prettier,
pure refactors with no behavior change, generated-code-only changes, CI/build/tooling
tweaks, test-only changes, merge commits, and revert pairs that cancel out. When a
commit is borderline and you cannot tell that anything user-visible changed, drop it.

### Write each kept commit as one entry

- `summary`: one concise, plain-language sentence in past tense, written for a human
  reader — not a git subject. Strip PR/issue numbers, "Claude-Session" trailers,
  co-author lines, and internal jargon. Describe the change and, when it helps, its
  benefit. Merge commits that are obviously the same change into one entry.
- `category`: `feature` (new capability), `fix` (bug fix), `improvement` (enhancement
  to existing behavior, perf, reliability), or `other` (anything kept that fits none).
- `pr_number`: copy from the commit if present, else omit.
- `issue_number`: copy from the commit if present, else omit.

### Empty is valid — and important

If a version has **no** worthwhile commits, still write its `notes_file` with
`"entries": []`. That empty record is what marks the version evaluated; without it the
release stays pending forever and is rebuilt on every run. Never skip writing a file.

## Rules

- Write every `notes_file` listed in the input. Nothing more.
- Write only those paths. Do not create or edit any other file, and do not run git —
  the CLI validates your output and posts it to platform.
- Output valid JSON only in the files (no comments, no trailing commas).
