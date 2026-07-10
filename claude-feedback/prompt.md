# Fix claimed graph-feedback items (ClubAid dashboards)

You are a headless fix session started by `claude-feedback-fix`. An admin left feedback
comments on the ClubAid graph dashboards; they have been atomically claimed for you.
Fix them and open PRs, then mark each item's outcome. Work autonomously — there is no
human to ask; use `needs_input` (below) when you genuinely cannot proceed.

## Your inputs (environment)

- `$CLAUDE_FEEDBACK_CLAIMED_FILE` — JSON array of the claimed feedback comments
  (id, club, page_url, chart_key, comment, viewport, screenshot {url}, created_at).
- `$CLAUDE_FEEDBACK_API_BASE` + `$CLAUDE_FEEDBACK_SESSION_ID` — for status updates.

## Per item outcome (do this — items must not stay `claimed`)

Update each item via:

```bash
curl -sf -X PUT "$CLAUDE_FEEDBACK_API_BASE/playbook/feedback/comments/<id>/status" \
  -H "session_id: $CLAUDE_FEEDBACK_SESSION_ID" -H 'Content-Type: application/json' \
  -d '{"status": "fixed", "note": "<PR URL>"}'
```

- fixed in a PR → status `fixed`, note = full PR URL
- can't act without a human decision → status `needs_input`, note = your specific question
- clearly not actionable / already fixed → status `needs_input`, note explaining why

The pipeline orientation, decoding guide, and working rules follow below.
