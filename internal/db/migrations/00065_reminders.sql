-- +goose Up
-- Reminders: the owner's ":later:" reaction (remind_me tool) parks a message to
-- resurface in the inbox action strip at remind_at. A reminder is inert until
-- due; "due" is derived at read time (status='pending' AND remind_at <= now),
-- so no daemon phase flips it. Read-only Slack: nothing is posted back (REMIND-02).
CREATE TABLE IF NOT EXISTS reminders (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id  INTEGER NOT NULL DEFAULT 0,
    message_ref TEXT    NOT NULL DEFAULT '',   -- "<channel_id>@<message_ts>" from the reaction binding
    note        TEXT    NOT NULL DEFAULT '',
    remind_at   TEXT    NOT NULL,
    status      TEXT    NOT NULL DEFAULT 'pending'
                CHECK(status IN ('pending','done','dismissed')),
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    done_at     TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status, remind_at);

-- Wave 2 dictionary breadth (feature still ships OFF; owner edits later).
INSERT OR IGNORE INTO reaction_command_map (emoji, kind, tool) VALUES
    ('eyes',             'builtin_tool', 'create_track'),
    ('bulb',             'builtin_tool', 'create_idea'),
    ('alarm_clock',      'builtin_tool', 'remind_me'),
    ('pushpin',          'builtin_tool', 'brief_context');

-- Default trust per the design §7 table. INSERT OR IGNORE: never overwrite an
-- owner's prior choice. create_jira_issue stays External-forced-ask elsewhere.
INSERT OR IGNORE INTO tool_trust (tool, trust) VALUES
    ('create_track',   'ask'),
    ('create_idea',    'execute'),
    ('remind_me',      'execute'),
    ('brief_context',  'execute');

-- +goose Down
DROP INDEX IF EXISTS idx_reminders_due;
DROP TABLE IF EXISTS reminders;
DELETE FROM reaction_command_map WHERE emoji IN ('eyes','bulb','alarm_clock','pushpin');
DELETE FROM tool_trust WHERE tool IN ('create_track','create_idea','remind_me','brief_context');
