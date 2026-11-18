-- +goose Up
-- Slack Developer Policy hygiene (#1769, spec 2026-11-17 §5.3; A14, A15, A26).
--
-- people_card_exclusions: people the owner stopped cards for (Stop card for
-- this person). user_id is the namespaced "<account>:<raw user id>"; written
-- only by `watchtower people exclude|include` (db.ExcludePerson /
-- db.IncludePerson); the guide pipeline skips these ids and the Slack purge
-- deletes an account's rows by namespace.
CREATE TABLE IF NOT EXISTS people_card_exclusions (
    user_id    TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- emoji_scope_missing: 1 = a legacy token (no recorded grant) answered
-- emoji.list with missing_scope; the emoji sync skips the account until a
-- re-login records a grant (A26).
ALTER TABLE slack_accounts ADD COLUMN emoji_scope_missing INTEGER NOT NULL DEFAULT 0;

-- people_prune_done_at: when the one-time pass that deletes this account's
-- people cards made for non-partners finished (db.PrunePreUpgradePeopleCards,
-- A13); '' = not yet (no owner known, or not run). New cards are limited to
-- partners when they are made, so the pass never repeats.
ALTER TABLE slack_accounts ADD COLUMN people_prune_done_at TEXT NOT NULL DEFAULT '';

-- Old profiling data does not outlive the change (A15): the dropped people
-- card fields go back to their defaults (the columns stay), Team Summary's
-- attention list empties, and the legacy tables nothing writes any more lose
-- their rows, with the feedback on the old analyses.
UPDATE people_cards SET active_hours_json = '{}', volume_change_pct = 0, avg_message_length = 0, red_flags = '[]';
UPDATE people_card_summaries SET attention = '[]';
DELETE FROM feedback WHERE entity_type = 'user_analysis';
DELETE FROM user_analyses;
DELETE FROM user_interactions;

-- +goose Down
-- The cleared data is not restored.
ALTER TABLE slack_accounts DROP COLUMN people_prune_done_at;
ALTER TABLE slack_accounts DROP COLUMN emoji_scope_missing;
DROP TABLE IF EXISTS people_card_exclusions;
