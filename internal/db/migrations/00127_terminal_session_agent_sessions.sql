-- +goose Up
-- Every agent session id a workbench terminal tab ever had. The tab's own
-- claude_session_id holds only the latest one (/clear and resume swap it), so
-- the session chat feed reads this ledger to stitch the tab's transcripts.
-- Ids and times only; no transcript text.
CREATE TABLE terminal_session_agent_sessions (
    terminal_session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    agent_session_id    TEXT NOT NULL,
    first_seen_at       TEXT NOT NULL,
    PRIMARY KEY (terminal_session_id, agent_session_id)
);

INSERT INTO terminal_session_agent_sessions (terminal_session_id, agent_session_id, first_seen_at)
SELECT id, claude_session_id, created_at FROM terminal_sessions WHERE claude_session_id IS NOT NULL;

-- Written in the writer's own statement, whoever the writer is (the Desktop
-- creates the row, Go moves the id on /clear and fills a codex row's id).
-- +goose StatementBegin
CREATE TRIGGER terminal_session_agent_sessions_ai AFTER INSERT ON terminal_sessions
WHEN NEW.claude_session_id IS NOT NULL
BEGIN
    INSERT OR IGNORE INTO terminal_session_agent_sessions (terminal_session_id, agent_session_id, first_seen_at)
    VALUES (NEW.id, NEW.claude_session_id, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER terminal_session_agent_sessions_au AFTER UPDATE OF claude_session_id ON terminal_sessions
WHEN NEW.claude_session_id IS NOT NULL
BEGIN
    INSERT OR IGNORE INTO terminal_session_agent_sessions (terminal_session_id, agent_session_id, first_seen_at)
    VALUES (NEW.id, NEW.claude_session_id, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER terminal_session_agent_sessions_au;
DROP TRIGGER terminal_session_agent_sessions_ai;
DROP TABLE terminal_session_agent_sessions;
