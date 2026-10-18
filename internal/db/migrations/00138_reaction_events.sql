-- +goose Up
-- Ledger of owner reactions already published as `slack.reaction_added`
-- automation events. A row means "seen"; the primary key makes the publish
-- exactly once per (account, channel, message, emoji), so removing and
-- re-adding a reaction never fires again. Separate from reaction_commands,
-- which stays the tool-dispatch ledger (REACT-01..05).
CREATE TABLE reaction_events (
    account_id INTEGER NOT NULL,
    channel_id TEXT    NOT NULL,
    message_ts TEXT    NOT NULL,
    emoji      TEXT    NOT NULL,
    seen_at    TEXT    NOT NULL,
    PRIMARY KEY (account_id, channel_id, message_ts, emoji)
);

-- When this account's existing reactions were recorded into reaction_events
-- without firing. Empty = never seeded; a stamp, not "the ledger is empty",
-- for the same reason as reaction_commands_seeded_at.
ALTER TABLE slack_accounts ADD COLUMN reaction_events_seeded_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE slack_accounts DROP COLUMN reaction_events_seeded_at;
DROP TABLE reaction_events;
