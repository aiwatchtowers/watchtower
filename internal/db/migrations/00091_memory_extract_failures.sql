-- +goose Up
-- Attempt budget for Slack episode extraction (MEM-04, amended 2026-10-01 with
-- the owner's approval). A window that fails deterministically (a degenerate
-- reply, a refusal, a context overflow) used to freeze the extraction
-- watermark forever: every run re-extracted the same chunk, re-spent the AI
-- calls and wrote fresh duplicate episodes for every window after it.
--
-- One row per failing window, keyed by its channel and its first message's
-- ts_unix (stable while the watermark is frozen below it). failures counts the
-- failures that proved the window itself is the problem (see
-- memory.countsTowardBudget); after extractBatchAttempts the window is
-- extracted alone, and after extractQuarantineAttempts it is quarantined:
-- quarantined_at is set and the window's messages, channel_id between
-- first_ts and last_ts, are skipped by later runs so the watermark can pass
-- them. A quarantined row is kept as the durable record of what memory never
-- read. A row is deleted when its window succeeds.
--
-- Runtime state, not vault-derived: deliberately NOT in DropMemoryIndex's
-- delete list (MEM-02 exclusion, the memory_step_state line) — a reindex that
-- erased it would un-quarantine a poison window and restart its spend.
CREATE TABLE IF NOT EXISTS memory_extract_failures (
    channel_id     TEXT NOT NULL,
    first_ts       REAL NOT NULL,
    last_ts        REAL NOT NULL,
    failures       INTEGER NOT NULL DEFAULT 0,
    last_error     TEXT NOT NULL DEFAULT '',
    quarantined_at TEXT NOT NULL DEFAULT '',
    updated_at     TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (channel_id, first_ts)
);

-- +goose Down
DROP TABLE IF EXISTS memory_extract_failures;
