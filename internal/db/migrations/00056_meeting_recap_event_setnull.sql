-- +goose NO TRANSACTION
-- +goose Up
-- meeting_recaps.event_id was the SOLE primary key with ON DELETE CASCADE, so
-- the daemon's stale-event cleanup (DeleteStaleCalendarEvents) wiped a meeting's
-- AI recap when its event aged out of the history window. Two changes fix that:
--   (1) a surrogate `id` PK + nullable UNIQUE `event_id` ON DELETE SET NULL —
--       the meeting_transcripts shape — so the cascade wipe becomes a null-out
--       (ON CONFLICT(event_id) and GetMeetingRecap(WHERE event_id=?) still work);
--   (2) a new nullable `transcript_id` REFERENCES meeting_transcripts(id) ON
--       DELETE SET NULL — the durable link that survives event deletion, so an
--       orphaned recap stays reachable via GetMeetingRecapByTranscript.
-- SQLite cannot ALTER a foreign key or PK, so recreate the table.
-- foreign_keys=OFF (not defer_foreign_keys) guards the DROP and keeps the
-- INSERT...SELECT / backfill from re-validating FKs mid-migration.
PRAGMA foreign_keys = OFF;

CREATE TABLE meeting_recaps_new (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id      TEXT UNIQUE REFERENCES calendar_events(id) ON DELETE SET NULL,
    transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
    source_text   TEXT NOT NULL,
    recap_json    TEXT NOT NULL,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
-- Copy existing rows (fresh AUTOINCREMENT ids); transcript_id starts NULL.
INSERT INTO meeting_recaps_new (event_id, source_text, recap_json, created_at, updated_at)
    SELECT event_id, source_text, recap_json, created_at, updated_at FROM meeting_recaps;
DROP TABLE meeting_recaps;
ALTER TABLE meeting_recaps_new RENAME TO meeting_recaps;

-- Backfill transcript_id from the transcript that shares the recap's event
-- (NULL when no transcript matches — ad-hoc/CLI-pasted recaps).
UPDATE meeting_recaps SET transcript_id = (
    SELECT mt.id FROM meeting_transcripts mt WHERE mt.event_id = meeting_recaps.event_id
) WHERE event_id IS NOT NULL;

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;

CREATE TABLE meeting_recaps_old (
    event_id    TEXT PRIMARY KEY REFERENCES calendar_events(id) ON DELETE CASCADE,
    source_text TEXT NOT NULL,
    recap_json  TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
-- A row whose event_id went NULL (its event was deleted) cannot satisfy the
-- restored event_id-PK; drop those on the way down. id + transcript_id dropped.
INSERT INTO meeting_recaps_old (event_id, source_text, recap_json, created_at, updated_at)
    SELECT event_id, source_text, recap_json, created_at, updated_at
    FROM meeting_recaps WHERE event_id IS NOT NULL;
DROP TABLE meeting_recaps;
ALTER TABLE meeting_recaps_old RENAME TO meeting_recaps;

PRAGMA foreign_keys = ON;
