# Catch-Up — absence recap (2026-09-04)

- `internal/catchup/` — `Pipeline.Run`: `resolveWindow → insert(building) → topUp → gather → compose → validate → persist`. Window: **auto** = since the most recently *acknowledged* recap's `period_to` (24h fallback when none exist), a preset (`today`/`yesterday`/`3d`/`week`), or custom `--from`/`--to`; capped at 31 days.
- Top-up (only when the window's `to` is within 5 min of now) reruns the existing channel-digest and Gmail/Jira stream-digest pipelines over the uncovered tail, gated by their own feature flags; a failed/skipped top-up is recorded in `coverage_json` and never fails the recap.
- One strong-tier `catchup.compose` call composes eight gathered window areas (digests/streams/meetings/transcripts/decisions/inbox/tracks/targets) into `tldr` + topics/decisions/meetings/needs_you; every `[area#id]` ref is validated against the gathered set — an unknown ref is dropped and counted, a zero-ref item is dropped.
- **"I'm caught up"** (`Pipeline.Acknowledge` / CLI `catchup ack`, and Swift `CatchUpQueries.acknowledge(recap:)` writing the DB directly) marks the whole window read on five `read_at` surfaces (digests, stream digests, tracks, inbox items, briefings) in one transaction, idempotently.
- Per-topic 👍/👎 + comment (`catchup feedback`) still derives learned rules for the source pipelines; a presentation-correction comment triggers a whole-recap `--regen` instead of just a rule.
- `catchup_recaps` table (migration 00061, replaces the old review-session schema); every run inserts a new row, nothing is edited in place except by `--regen`.
- See `docs/inventory/catchup.md` for CATCHUP-01..04 and `docs/superpowers/specs/2026-09-04-catchup-absence-recap-design.md`.
