-- +goose Up
-- A working codex row whose rollout the session host's watch cannot read
-- (§3.5 of the transport independence spec, G5): the class only, never a
-- path. Written over a `working` codex row only; the next hook event clears it.
ALTER TABLE terminal_sessions ADD COLUMN agent_watch_issue TEXT
    CHECK(agent_watch_issue IN ('missing','permission','compressed','unreadable'));
ALTER TABLE terminal_sessions ADD COLUMN agent_watch_issue_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_watch_issue_at;
ALTER TABLE terminal_sessions DROP COLUMN agent_watch_issue;
