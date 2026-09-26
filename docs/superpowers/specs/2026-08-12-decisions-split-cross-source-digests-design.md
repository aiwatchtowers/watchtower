# Decisions Split + Cross-Source Digests — Design

**Date:** 2026-08-12
**Owner decisions baked in:** the Ideas registry narrows to ideas & proposals (things not yet decided — the "don't lose it" value); decisions are a *journal*, not a triage queue — mined decisions are born `active` and never ask for approval; the Digests tab becomes the cross-source overview (Slack + Gmail + Jira + meetings) and its Decisions segment becomes the one deduplicated, cross-source decisions ledger; dedup is required from v1 ("noise repels the user") and is provided by the existing ideas consolidator, not a new mechanism.

## Problem

The Ideas registry mines decisions from all sources into the same `proposed` review queue as ideas. In practice the owner's "For review" list filled with 49 already-made decisions — nothing to approve, pure noise. Meanwhile the product already has a decisions surface (Digests → Decisions), but it is Slack-only (`digests.decisions` JSON), effectively unused (~7.5% read, mostly via digest-read cascade), and undeduplicated across sources. Gmail/Jira stream digests (`stream_digests`) exist as stage-1 substrate but are invisible in the UI, and their generation — plus the Jira comment sync feeding INBOX-02 — is gated on `ideas.enabled`, an unrelated feature's switch (flagged 2026-08-08 in `docs/inventory/inbox-pulse.md`).

## Goals

1. Ideas tab = ideas & proposals only. Review queue and sidebar badge count ideas/notes, never decisions.
2. Decisions = a quiet cross-source ledger with dedup and mention chronology, living in Digests → Decisions, fed by the existing consolidator.
3. Digests tab shows all streams: Slack channel digests, Gmail/Jira stream digests, meeting recaps — one feed, grouped by day, labeled by source.
4. Stage-1 stream-digest generation and Jira comment sync run independently of `ideas.enabled` (fixes the INBOX-02 coupling).

## Non-goals (v1)

- No changes to the consolidator's dedup mechanics (IDEA-05) or provenance validation (IDEA-02).
- No read-tracking for meeting-recap rows in the feed (recaps have no unread concept anywhere today).
- No importance scoring for ledger decisions (`decision_importance_corrections` stays with the legacy Slack path; the ledger has 👍/👎 instead).
- No decisions→target conversion (unchanged non-goal from the registry design).
- Catch-up ack does not touch ledger decisions (the old digest→decision_reads cascade becomes vestigial and is removed; the ledger is an independent journal).
- Slack digest generation, briefing, memory digest-compare: untouched.

## Part A — Registry split (Go + Swift)

### A1. Mined decisions born `active`

`applyNewIdeaOp` (`internal/ideas/consolidate.go`): when `op.Op == "new_decision"`, set `Status: "active"` on the created row (ideas keep the empty status → `CreateIdeaTx` default `proposed`). `active` is already in the status CHECK — no schema change. `ListIdeasForPrompt` already includes `active`, so the consolidator's registry slice keeps decisions dedup-aware.

IDEA-01..05 are untouched mechanically. IDEA-04 (resurfacing sets `needs_review` on `not_now/dropped/rejected` targets) keeps working; those statuses are simply no longer reachable for decisions via the UI, so in practice it applies to ideas.

### A2. Migration 00053

```sql
-- +goose Up
UPDATE ideas SET status = 'active', updated_at = datetime('now')
 WHERE kind = 'decision' AND status = 'proposed';
ALTER TABLE ideas ADD COLUMN seen_at TEXT;
ALTER TABLE stream_digests ADD COLUMN read_at TEXT;
```

- The flip converts the existing backlog of proposed decisions into journal entries (no data loss — the deliberate alternative to deleting them).
- `ideas.seen_at` is the ledger's read marker (Decisions segment unread state; NULL = unread). Ideas-tab flows never touch it.
- `stream_digests.read_at` is the feed's read marker for Gmail/Jira digest rows (the `digests.read_at` precedent; a column, not a reads table — single-owner app).
- Down: drop via table-recreation only if needed; statuses are not reverted (accepted).
- Mirror both columns into `internal/db/schema.sql`, regenerate the schema golden.

### A3. Review-queue predicates exclude decisions

Add `AND kind != 'decision'` to the review predicate in both dual-path homes (change as a pair):

- Go `CountIdeasForReview` (`internal/db/ideas.go`).
- Swift `IdeaQueries.fetchForReview` / `countForReview` (badge) and the `excludingReviewQueue` arm of `fetchList`.

This is belt-and-braces: after A1+A2 no decision should be `proposed`, but a `needs_review` decision (IDEA-04 edge) must surface in the Decisions segment — covered by its unread predicate (`seen_at IS NULL OR needs_review = 1`) — not in the Ideas queue.

### A4. Ideas tab narrows (Swift)

- `IdeasView`: kind filter drops "Decisions"; status filter drops `superseded`/`reversed`; empty-state copy → "Ideas and proposals mined from Slack, meetings, email, and Jira…".
- `IdeaCreateSheet`: kinds = Idea / Note. Manual decision creation moves to the Decisions segment (a "+" there; `createManual(kind: "decision")` already births `active`/`owner`).
- `IdeaDetailPane`: the `kind == .decision` arm (Supersede/Reverse) moves to the new Decisions detail; kind glyph/badge maps for `.decision` move with it (shared helpers stay in one place — `IdeaRow`'s glyph mapping is reused by the ledger list).
- `IdeasViewModel.supersede/reverse` move to (or are shared with) the Decisions view model.
- MCP `list_ideas`/`get_idea`, `get_task_context`: unchanged — they read the same rows.

## Part B — Cross-source Digests tab

### B1. Go: stage-1 decoupled from `ideas.enabled`

- Split `Pipeline.Run` (`internal/ideas/pipeline.go`): new exported `RunStreamDigests(ctx)` = `runEmailDigests` + `runJiraDigests`; `Run` keeps consolidation (stage 2) behind `Ideas.Enabled` and no longer runs stage 1 itself.
- New config block: `streams.enabled` (default **true**) and `streams.interval_hours` (default 6). `ideas.enabled` / `ideas.mine_interval_hours` keep gating stage 2 only.
- New daemon phase `phaseStreamDigests` (before `phaseIdeas`, so the consolidator sees fresh streams): own `lastStreams` throttle keyed on `streams.interval_hours`, own `trackedPipelineRun("stream-digests", ...)` label, and it respects the ideas backfill lock (`ideas.AcquireBackfillLock` freshness check — skip while a CLI backfill holds it; same rule as `phaseIdeas`).
- `wireIdeasPipeline` (`cmd/ideas.go`): construct and wire the pipeline when `streams.enabled || ideas.enabled` (today it returns early when ideas are off, which would kill the new phase too).
- Jira comment sync (`cmd/sync.go`): `SetCommentSyncLimit` gates on `streams.enabled` instead of `ideas.enabled` (limit stays `ideas.max_comment_issues_per_sync`). With the default on, `jira_comments` sync — and the dormant INBOX-02 `jira_comment_mention` path — become live by default. Update the 2026-08-08 coupling note in `docs/inventory/inbox-pulse.md`.
- `ideas mine` CLI + backfill: unchanged (backfill drives stage 1 via `runStage1Passes` under the registry's own gate, as today).
- IDEA-01 floor semantics unchanged; stage-1 floors (`ideas_email_floor`/`ideas_jira_floor`) advance exactly as today.

### B2. Swift: the feed (Digests segment)

One chronological feed, grouped by day, each row labeled by source:

- **Slack** — existing `digests` rows (`DigestQueries.fetchAll`), existing `DigestDetailView`, existing unread (`read_at`).
- **Gmail / Jira** — new `StreamDigest` model + `StreamDigestQueries` (greenfield; `stream_digests` has zero Swift consumers today). Row shows scope/period + topic titles; new `StreamDigestDetailView` renders `topics_json` (title, summary, ideas[], decisions[] with refs → Gmail deep link / Jira browse URL via the account's `site_url`). Unread via `read_at`, marked on open.
- **Meetings** — rows from `MeetingTranscriptQueries.fetchRecordingList` filtered to `has_recap`; detail renders the recap via existing `MeetingRecap.Content` parsing (no new query on `meeting_recaps` beyond a by-transcript fetch already available in the recording detail path). No unread state (non-goal). Row links through to the full recording in Calendar.

`DigestViewModel` grows the union assembly (stays view-local — browsing state, not an async op). The digests sidebar badge stays Slack-unread-only in v1; segment labels show per-segment unread counts as today.

### B3. Swift: the Decisions segment reads the ledger

- Data source: `ideas WHERE kind = 'decision'` (new `DecisionLedgerQueries` or an `IdeaQueries.fetchList(kind: "decision", …)` reuse), ordered by `last_mention_at DESC`. `DecisionEntry`/`decision_reads`/importance-correction machinery is retired from this segment (the models stay only if the legacy flat-decisions section of `DigestDetailView` still needs them; `ChannelStatsQueries` keeps counting `digest_topics` — untouched).
- Row: title, source glyphs from mentions, relative time, unread dot (`seen_at IS NULL OR needs_review = 1`). Expand/open marks seen (`seen_at = now`, clears nothing else). "Mark all read" batch.
- Detail: essence, status badge (`active`/`superseded`/`reversed`), Supersede / Reverse actions (moved from IdeaDetailPane), 👍/👎 + comment (same `setRating`), mentions chronology with deep links (reuse the Ideas mention rendering), Discuss chat stays available (same `context_type='idea'`).
- Unread count for the segment label = `COUNT(*) WHERE kind='decision' AND (seen_at IS NULL OR needs_review=1)`.
- `DigestWatcher` decision notifications (`notifyDecisions`): switch the source from `digest.parsedDecisions` to new ledger rows (max-id watermark over `ideas WHERE kind='decision'`), so notifications become cross-source and deduplicated. `CatchUpQueries`' `markAllDecisionsRead` cascade is removed (vestigial); `decision_reads` table stays in place, unused (non-destructive).

## Docs & contracts

- `docs/inventory/ideas.md`: note the birth-status change for decisions (no numbered-contract change — IDEA-01..05 untouched; explicit note that the review queue is ideas-only by design).
- `docs/inventory/inbox-pulse.md`: rewrite the 2026-08-08 INBOX-02 coupling entry — comment sync now rides `streams.enabled`.
- `CLAUDE.md` feature notes + `docs/app-guide.md` (UI changed: Ideas tab scope, Digests tab feed, Decisions ledger).

## Testing

- Go: consolidate test — `new_decision` op lands `active`, `new_idea` still `proposed`; migration test — flip + new columns in `TestAllTablesExist`/schema golden; daemon — `phaseStreamDigests` runs with `ideas.enabled=false` and skips under a fresh backfill lock; wiring — comment-sync limit set when `streams.enabled` regardless of `ideas.enabled`; `CountIdeasForReview` excludes decisions.
- Swift: `IdeaQueriesTests` (review predicates exclude decisions; seen_at untouched by idea flows), new `StreamDigestQueriesTests`, decisions-ledger VM tests (unread count incl. `needs_review`, mark-seen, supersede/reverse), `SidebarCountsViewModelTests` (badge = ideas only), `DigestWatcherTests` (ledger-sourced notifications), `CatchUpQueriesTests` (cascade removal).
- Guard rails: no changes to IDEA-01..05 guard tests' assertions.

## Rollout

One branch (`feature/decisions-split`), one PR, granular commits (A1-A4, B1, B2, B3, docs). Local-review gate before the PR; merge after green CI (owner pre-approved).
