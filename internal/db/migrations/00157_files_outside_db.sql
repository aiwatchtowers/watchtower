-- +goose Up
-- Company content that used to sit in files outside the database (#604
-- Stage A, spec docs/superpowers/specs/2026-10-25-files-outside-db-design.md):
-- automation_draft_cache replaces <workspace>/automation-drafts/<id>.jsonl
-- (Go writes it, the Desktop's Draft panel reads it; its rows go with their
-- conversation by cascade); pending_transcripts
-- replaces the recording sidecars rec_*.meta|txt|json and chat_queued_drafts
-- the queued embedded-chat draft in UserDefaults — both written by the
-- Desktop only (Go never reads or writes them).
CREATE TABLE automation_draft_cache (
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    seq             INTEGER NOT NULL,
    entry_json      TEXT NOT NULL,
    at              TEXT NOT NULL,
    PRIMARY KEY (conversation_id, seq)
);

CREATE TABLE pending_transcripts (
    recording      TEXT PRIMARY KEY,
    event_id       TEXT,
    title          TEXT,
    transcript     TEXT,
    meta_json      TEXT,
    started_at     REAL NOT NULL,
    transcribed_at REAL
);

CREATE TABLE chat_queued_drafts (
    surface_key TEXT PRIMARY KEY,
    text        TEXT NOT NULL,
    at          REAL NOT NULL
);

-- +goose Down
DROP TABLE chat_queued_drafts;
DROP TABLE pending_transcripts;
DROP TABLE automation_draft_cache;
