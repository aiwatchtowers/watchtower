-- +goose Up
-- Secretary memory Phase 5 slice-2, Task 2: the calendar episode-build
-- watermark. See docs/superpowers/plans/2026-07-16-memory-phase5-slice2.md
-- Task 2. A single additive ALTER TABLE ADD COLUMN — no CHECK constraint
-- change, no new table, so no table-recreation dance and no PRAGMA
-- foreign_keys toggling is needed here.

-- Calendar episode-build watermark: unix seconds of the newest ENDED
-- calendar_events.end_time fully folded into an episode by the mechanical
-- past-event->episode builder (memory.sources.calendar). Deliberately a
-- FOURTH independent watermark, distinct from memory_last_extracted_ts
-- (Slack episode extraction, see 00017), memory_gmail_last_extracted_ts
-- (Gmail episode extraction, see 00042), and memory_last_interaction_id (5D
-- interaction-ingest floor, see 00042). It advances only behind
-- fully-committed event episodes and never past an un-built event (MEM-04,
-- adapted); the builder additionally re-scans a bounded lookback overlap so
-- a recap/edit landing after the watermark passed a still-present event
-- refreshes its episode via the calevent: alias update-path (resolved
-- ambiguity #3) — that overlap is a code const, not a schema change.
ALTER TABLE workspace ADD COLUMN memory_calendar_last_extracted_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
-- Precedent: 00017-00019, 00042's Down drops their ALTER-added columns so a
-- down;up cycle is clean.
ALTER TABLE workspace DROP COLUMN memory_calendar_last_extracted_ts;
