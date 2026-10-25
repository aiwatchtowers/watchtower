-- +goose NO TRANSACTION
-- +goose Up
-- Owner instructions reach every AI chat (spec 2026-10-23-chat-owner-instructions-design.md):
-- owner_instructions gains the 'chat' scope, instruction_suggestions the 'chat'
-- field (CHECK rebuilds), and instruction_chat_lines records each line a
-- "remember:" message appended, so the chat can offer Undo and Settings a link.
-- No foreign keys on the ledger: chat rows may be deleted later.
-- The rebuild is one transaction (one goose statement); foreign keys stay OFF
-- around it because instruction_suggestions references projects.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE owner_instructions_new (
    scope      TEXT PRIMARY KEY CHECK (scope IN ('session','procedure','chat')),
    body       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
INSERT INTO owner_instructions_new (scope, body, updated_at)
    SELECT scope, body, updated_at FROM owner_instructions;
DROP TABLE owner_instructions;
ALTER TABLE owner_instructions_new RENAME TO owner_instructions;

CREATE TABLE instruction_suggestions_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    text            TEXT NOT NULL,
    field           TEXT NOT NULL CHECK (field IN ('session','procedure','chat')),
    workbench_id    INTEGER NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_count   INTEGER NOT NULL DEFAULT 0,
    workbench_count INTEGER NOT NULL DEFAULT 0,
    first_seen_at   TEXT NOT NULL,
    last_seen_at    TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','added','dismissed')),
    fingerprint     TEXT NOT NULL UNIQUE,
    decided_at      TEXT NULL
);
INSERT INTO instruction_suggestions_new
    (id, text, field, workbench_id, session_count, workbench_count, first_seen_at, last_seen_at, status, fingerprint, decided_at)
    SELECT id, text, field, workbench_id, session_count, workbench_count, first_seen_at, last_seen_at, status, fingerprint, decided_at
    FROM instruction_suggestions;
DELETE FROM sqlite_sequence WHERE name = 'instruction_suggestions_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'instruction_suggestions_new', seq FROM sqlite_sequence WHERE name = 'instruction_suggestions';
DROP TABLE instruction_suggestions;
ALTER TABLE instruction_suggestions_new RENAME TO instruction_suggestions;
CREATE INDEX IF NOT EXISTS idx_instruction_suggestions_status ON instruction_suggestions(status, first_seen_at);

CREATE TABLE instruction_chat_lines (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    line            TEXT NOT NULL,
    conversation_id INTEGER NULL,
    message_id      INTEGER NULL,
    added_at        TEXT NOT NULL
);
CREATE INDEX idx_instruction_chat_lines_message ON instruction_chat_lines(message_id);

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

DROP INDEX idx_instruction_chat_lines_message;
DROP TABLE instruction_chat_lines;

DELETE FROM owner_instructions WHERE scope = 'chat';
CREATE TABLE owner_instructions_old (
    scope      TEXT PRIMARY KEY CHECK (scope IN ('session','procedure')),
    body       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
INSERT INTO owner_instructions_old (scope, body, updated_at)
    SELECT scope, body, updated_at FROM owner_instructions;
DROP TABLE owner_instructions;
ALTER TABLE owner_instructions_old RENAME TO owner_instructions;

DELETE FROM instruction_suggestions WHERE field = 'chat';
CREATE TABLE instruction_suggestions_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    text            TEXT NOT NULL,
    field           TEXT NOT NULL CHECK (field IN ('session','procedure')),
    workbench_id    INTEGER NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_count   INTEGER NOT NULL DEFAULT 0,
    workbench_count INTEGER NOT NULL DEFAULT 0,
    first_seen_at   TEXT NOT NULL,
    last_seen_at    TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','added','dismissed')),
    fingerprint     TEXT NOT NULL UNIQUE,
    decided_at      TEXT NULL
);
INSERT INTO instruction_suggestions_old
    (id, text, field, workbench_id, session_count, workbench_count, first_seen_at, last_seen_at, status, fingerprint, decided_at)
    SELECT id, text, field, workbench_id, session_count, workbench_count, first_seen_at, last_seen_at, status, fingerprint, decided_at
    FROM instruction_suggestions;
DELETE FROM sqlite_sequence WHERE name = 'instruction_suggestions_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'instruction_suggestions_old', seq FROM sqlite_sequence WHERE name = 'instruction_suggestions';
DROP TABLE instruction_suggestions;
ALTER TABLE instruction_suggestions_old RENAME TO instruction_suggestions;
CREATE INDEX IF NOT EXISTS idx_instruction_suggestions_status ON instruction_suggestions(status, first_seen_at);

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
