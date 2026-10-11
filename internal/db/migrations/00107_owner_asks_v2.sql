-- +goose Up
-- Owner asks v2 (board #314).
--
-- owner_presence: the one session the owner is looking at, written by the
-- Desktop only (enter and every 30 s heartbeat upsert session_id + seen_at;
-- leaving, lock, sleep and quit upsert session_id NULL), read by Go. A
-- singleton keeps "at most one present session" structural. seen_at uses the
-- agent_state_at format; a write older than 90 s reads as absent.
CREATE TABLE IF NOT EXISTS owner_presence (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    seen_at    TEXT NOT NULL DEFAULT ''
);

-- A short question the Stop ask guard let through as terminal text while the
-- owner was present (Go-only writes). chat_question: JSON
-- {"question": "...", "options": [{"label","recommended"}]}; NULL = none.
-- chat_question_at: the guard's Stop time, agent_state_at format; NULL with
-- chat_question. Never touches the agent state columns.
ALTER TABLE terminal_sessions ADD COLUMN chat_question TEXT;
ALTER TABLE terminal_sessions ADD COLUMN chat_question_at TEXT;

-- level: Go's stored classification (quick = banner, full = drawer).
-- origin: chat = a Chat question Watchtower raised itself after it waited.
-- chat_asked_at: origin chat only, when the question was asked in the
-- terminal; '' otherwise (the invariant is enforced by InsertOwnerAsk).
-- Existing asks stay full / agent / ''.
ALTER TABLE owner_asks ADD COLUMN level TEXT NOT NULL DEFAULT 'full' CHECK (level IN ('quick','full'));
ALTER TABLE owner_asks ADD COLUMN origin TEXT NOT NULL DEFAULT 'agent' CHECK (origin IN ('agent','chat'));
ALTER TABLE owner_asks ADD COLUMN chat_asked_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE owner_asks DROP COLUMN chat_asked_at;
ALTER TABLE owner_asks DROP COLUMN origin;
ALTER TABLE owner_asks DROP COLUMN level;
ALTER TABLE terminal_sessions DROP COLUMN chat_question_at;
ALTER TABLE terminal_sessions DROP COLUMN chat_question;
DROP TABLE IF EXISTS owner_presence;
