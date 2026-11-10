-- +goose Up
-- Every agent session id a deleted terminal session had (auto cleanup spec
-- 2026-11-10 §2b). A row's ledger in terminal_session_agent_sessions
-- cascades away with it, so without this a uuid two rows shared would look
-- like the survivor's alone once the other was deleted, and the survivor's
-- cleanup would adopt the deleted row's scratchpad lanes. No foreign key:
-- the tombstone outlives the row. Ids and times only.
CREATE TABLE agent_session_tombstones (
    agent_session_id TEXT PRIMARY KEY,
    deleted_at       TEXT NOT NULL
);

-- BEFORE DELETE so the row's ledger is still there (it cascades after);
-- fires for a workbench delete's cascade too.
-- +goose StatementBegin
CREATE TRIGGER agent_session_tombstones_bd BEFORE DELETE ON terminal_sessions
BEGIN
    INSERT OR IGNORE INTO agent_session_tombstones (agent_session_id, deleted_at)
    SELECT agent_session_id, strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM terminal_session_agent_sessions WHERE terminal_session_id = OLD.id;
    INSERT OR IGNORE INTO agent_session_tombstones (agent_session_id, deleted_at)
    SELECT OLD.claude_session_id, strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE OLD.claude_session_id IS NOT NULL;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER agent_session_tombstones_bd;
DROP TABLE agent_session_tombstones;
