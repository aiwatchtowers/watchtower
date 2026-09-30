-- +goose Up
-- Embedded terminal sessions (spec 2026-09-30-project-workspace-sessions).
-- project_id NULL = a standalone terminal. The Desktop writes every column;
-- Go writes only title with title_source='ai' (`watchtower terminal title`).
CREATE TABLE terminal_sessions (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id        INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL CHECK(kind IN ('claude','shell')),
    title             TEXT NOT NULL,
    title_source      TEXT NOT NULL DEFAULT 'auto' CHECK(title_source IN ('auto','ai','user')),
    target_id         INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    folder_path       TEXT NOT NULL,
    claude_session_id TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_active_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    closed_at         TEXT,
    CHECK (title != '' AND folder_path != ''),
    CHECK (kind = 'shell' OR claude_session_id IS NOT NULL)
);
CREATE INDEX idx_terminal_sessions_project ON terminal_sessions(project_id, last_active_at);
CREATE INDEX idx_terminal_sessions_target ON terminal_sessions(target_id);

-- +goose Down
DROP INDEX IF EXISTS idx_terminal_sessions_target;
DROP INDEX IF EXISTS idx_terminal_sessions_project;
DROP TABLE IF EXISTS terminal_sessions;
