-- +goose Up
-- Agent actions: every write tool the assistant calls lands here as a
-- proposal first (spec docs/superpowers/specs/2026-09-04-agent-actions-design.md).
-- Rows are the approval queue AND the audit log — never deleted.
CREATE TABLE IF NOT EXISTS agent_actions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tool            TEXT    NOT NULL,
    external        INTEGER NOT NULL DEFAULT 0,
    args_json       TEXT    NOT NULL,
    reason          TEXT    NOT NULL DEFAULT '',
    surface         TEXT    NOT NULL DEFAULT '',
    conversation_id INTEGER NOT NULL DEFAULT 0,
    context_type    TEXT    NOT NULL DEFAULT '',
    context_id      TEXT    NOT NULL DEFAULT '',
    turn_id         TEXT    NOT NULL DEFAULT '',
    -- `executing` is the claim Apply takes before it runs the tool, so two
    -- overlapping applies can never both perform the write (AGENT-05).
    status          TEXT    NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','approved','rejected','applied','failed','executing')),
    trust_at_create TEXT    NOT NULL DEFAULT 'ask' CHECK(trust_at_create IN ('ask','execute')),
    result_json     TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    decided_at      TEXT    NOT NULL DEFAULT '',
    applied_at      TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_agent_actions_conversation ON agent_actions(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_actions_status ON agent_actions(status);

CREATE TABLE IF NOT EXISTS tool_trust (
    tool       TEXT PRIMARY KEY,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- +goose Down
DROP TABLE IF EXISTS tool_trust;
DROP INDEX IF EXISTS idx_agent_actions_status;
DROP INDEX IF EXISTS idx_agent_actions_conversation;
DROP TABLE IF EXISTS agent_actions;
