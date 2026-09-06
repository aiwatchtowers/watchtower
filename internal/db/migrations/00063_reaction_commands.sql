-- +goose Up
-- Reaction commands: the owner drives Watchtower by reacting in Slack. A
-- reaction whose emoji is in the dictionary becomes a command — Watchtower
-- gathers the message's context and dispatches an agent-action.
-- Spec: docs/superpowers/specs/2026-09-05-reaction-commands-design.md (REACT-01..05).

-- The dictionary: emoji -> action. `kind` is the extension point (REACT design
-- §7): `builtin_tool` maps to a registered agent-actions tool (`tool`); `agent`
-- maps to a custom owner-authored handler (`handler_id`, forward-compat — the
-- handler table and its runtime land in a later wave, gated on runtime B).
CREATE TABLE IF NOT EXISTS reaction_command_map (
    emoji      TEXT PRIMARY KEY,
    kind       TEXT    NOT NULL DEFAULT 'builtin_tool'
               CHECK(kind IN ('builtin_tool','agent')),
    tool       TEXT    NOT NULL DEFAULT '',
    handler_id INTEGER NOT NULL DEFAULT 0,
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- The ledger: one row per owner reaction the poll has already seen. The UNIQUE
-- key is the idempotency guard (REACT-03) — re-polling reactions.list never
-- re-dispatches a command already recorded here.
CREATE TABLE IF NOT EXISTS reaction_commands (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL,
    channel_id TEXT    NOT NULL,
    message_ts TEXT    NOT NULL,
    emoji      TEXT    NOT NULL,
    status     TEXT    NOT NULL DEFAULT 'pending'
               CHECK(status IN ('pending','dispatched','skipped','failed')),
    action_id  INTEGER NOT NULL DEFAULT 0,
    error      TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(account_id, channel_id, message_ts, emoji)
);
CREATE INDEX IF NOT EXISTS idx_reaction_commands_status ON reaction_commands(status);

-- Default dictionary (feature ships OFF; the owner edits this later). The two
-- verbs that map to tools already registered in internal/tools.
INSERT OR IGNORE INTO reaction_command_map (emoji, kind, tool) VALUES
    ('white_check_mark', 'builtin_tool', 'create_target'),
    ('ticket',           'builtin_tool', 'create_jira_issue');

-- +goose Down
DROP INDEX IF EXISTS idx_reaction_commands_status;
DROP TABLE IF EXISTS reaction_commands;
DROP TABLE IF EXISTS reaction_command_map;
