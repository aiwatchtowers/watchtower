-- +goose Up
-- Meeting transcripts: locally-transcribed meeting audio (WhisperKit in the
-- Desktop app). One row per recording. event_id is NULL for ad-hoc recordings
-- and survives event deletion (SET NULL) — a transcript must outlive its
-- calendar event. audio_path is NULLed by the daemon retention phase once the
-- audio file is deleted; transcript_text is kept forever. summary_json holds
-- the recap for ad-hoc recordings only (event-linked recaps live in
-- meeting_recaps).
CREATE TABLE meeting_transcripts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        TEXT REFERENCES calendar_events(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,
    audio_path      TEXT,
    duration_sec    INTEGER NOT NULL DEFAULT 0,
    lang_stats      TEXT NOT NULL DEFAULT '',
    transcript_text TEXT NOT NULL,
    summary_json    TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX idx_meeting_transcripts_event ON meeting_transcripts(event_id);

-- +goose Down
DROP TABLE meeting_transcripts;
