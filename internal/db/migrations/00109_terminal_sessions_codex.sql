-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Codex as a Workbench agent (board #399, spec
-- 2026-10-12-codex-workbench-agent-design §3.1).
--
-- 1. kind gains 'codex'. Codex mints its own session id and reports it only
--    with its first SessionStart, so a codex row may hold a NULL
--    claude_session_id until then; a claude row still needs one. The column
--    keeps its name: it is the agent's own session id (Claude Code or Codex).
-- 2. agent_transcript_path: the transcript path the SessionStart hook
--    reported, written by Go for every agent kind; NULL = none reported.
--
-- SQLite has no ALTER CONSTRAINT, so this is the table-recreation dance.
-- terminal_sessions is a parent (terminal_session_targets ON DELETE CASCADE,
-- owner_asks and owner_presence ON DELETE SET NULL), hence
-- PRAGMA foreign_keys = OFF around the whole migration (NO TRANSACTION)
-- rather than defer_foreign_keys (see the 00002 incident note in the
-- add-migration skill). DROP TABLE takes both indexes with it; they are
-- recreated below. The table has no triggers.

CREATE TABLE terminal_sessions_new (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id        INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL CHECK(kind IN ('claude','codex','shell')),
    title             TEXT NOT NULL,
    title_source      TEXT NOT NULL DEFAULT 'auto' CHECK(title_source IN ('auto','ai','user')),
    target_id         INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    folder_path       TEXT NOT NULL,
    claude_session_id TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_active_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    closed_at         TEXT,
    agent_state       TEXT CHECK (agent_state IN ('working','waiting','approval')),
    agent_state_at    TEXT,
    finished_at       TEXT,
    finish_summary    TEXT NOT NULL DEFAULT '',
    agent_failed_at   TEXT,
    agent_error       TEXT NOT NULL DEFAULT '',
    agent_turn_end    INTEGER,
    agent_tool_run    INTEGER NOT NULL DEFAULT 0,
    agent_background  INTEGER CHECK (agent_background IS NULL OR agent_background >= 0),
    agent_background_at TEXT,
    chat_question     TEXT,
    chat_question_at  TEXT,
    agent_turns       TEXT,
    agent_transcript_path TEXT,
    CHECK (title != '' AND folder_path != ''),
    CHECK (kind <> 'claude' OR claude_session_id IS NOT NULL)
);
INSERT INTO terminal_sessions_new (id, project_id, kind, title, title_source, target_id, folder_path,
    claude_session_id, created_at, last_active_at, closed_at, agent_state, agent_state_at, finished_at,
    finish_summary, agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
    agent_background_at, chat_question, chat_question_at, agent_turns)
SELECT id, project_id, kind, title, title_source, target_id, folder_path,
    claude_session_id, created_at, last_active_at, closed_at, agent_state, agent_state_at, finished_at,
    finish_summary, agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
    agent_background_at, chat_question, chat_question_at, agent_turns
FROM terminal_sessions;
DROP TABLE terminal_sessions;
ALTER TABLE terminal_sessions_new RENAME TO terminal_sessions;
CREATE INDEX idx_terminal_sessions_project ON terminal_sessions(project_id, last_active_at);
CREATE INDEX idx_terminal_sessions_target ON terminal_sessions(target_id);

PRAGMA foreign_keys = ON;

-- +goose Down
-- Codex rows cannot live in the 00108 table: they are deleted first, with
-- foreign keys still on, so their target links cascade away and their asks
-- and the owner's presence detach (session_id NULL), as for any deleted
-- session. agent_transcript_path is dropped with the rebuild.
DELETE FROM terminal_sessions WHERE kind = 'codex';

PRAGMA foreign_keys = OFF;

CREATE TABLE terminal_sessions_old (
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
    agent_state       TEXT CHECK (agent_state IN ('working','waiting','approval')),
    agent_state_at    TEXT,
    finished_at       TEXT,
    finish_summary    TEXT NOT NULL DEFAULT '',
    agent_failed_at   TEXT,
    agent_error       TEXT NOT NULL DEFAULT '',
    agent_turn_end    INTEGER,
    agent_tool_run    INTEGER NOT NULL DEFAULT 0,
    agent_background  INTEGER CHECK (agent_background IS NULL OR agent_background >= 0),
    agent_background_at TEXT,
    chat_question     TEXT,
    chat_question_at  TEXT,
    agent_turns       TEXT,
    CHECK (title != '' AND folder_path != ''),
    CHECK (kind = 'shell' OR claude_session_id IS NOT NULL)
);
INSERT INTO terminal_sessions_old (id, project_id, kind, title, title_source, target_id, folder_path,
    claude_session_id, created_at, last_active_at, closed_at, agent_state, agent_state_at, finished_at,
    finish_summary, agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
    agent_background_at, chat_question, chat_question_at, agent_turns)
SELECT id, project_id, kind, title, title_source, target_id, folder_path,
    claude_session_id, created_at, last_active_at, closed_at, agent_state, agent_state_at, finished_at,
    finish_summary, agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background,
    agent_background_at, chat_question, chat_question_at, agent_turns
FROM terminal_sessions;
DROP TABLE terminal_sessions;
ALTER TABLE terminal_sessions_old RENAME TO terminal_sessions;
CREATE INDEX idx_terminal_sessions_project ON terminal_sessions(project_id, last_active_at);
CREATE INDEX idx_terminal_sessions_target ON terminal_sessions(target_id);

PRAGMA foreign_keys = ON;
