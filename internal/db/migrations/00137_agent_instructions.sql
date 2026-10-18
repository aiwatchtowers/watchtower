-- +goose Up
-- Agent instructions: owner-written session instructions and target procedure
-- (global rows, per-workbench columns) plus mined repeat suggestions.
CREATE TABLE owner_instructions (
    scope      TEXT PRIMARY KEY CHECK (scope IN ('session','procedure')),
    body       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
ALTER TABLE projects ADD COLUMN session_instructions TEXT NULL;
ALTER TABLE projects ADD COLUMN target_procedure TEXT NULL;
CREATE TABLE instruction_suggestions (
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
CREATE INDEX idx_instruction_suggestions_status ON instruction_suggestions(status, first_seen_at);

-- +goose Down
DROP INDEX idx_instruction_suggestions_status;
DROP TABLE instruction_suggestions;
ALTER TABLE projects DROP COLUMN target_procedure;
ALTER TABLE projects DROP COLUMN session_instructions;
DROP TABLE owner_instructions;
