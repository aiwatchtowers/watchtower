-- +goose Up
-- When this account's pre-existing reaction history was recorded into the
-- reaction_commands ledger as `skipped`. The reaction-commands poll seeds an
-- account whose stamp is empty on its first poll instead of dispatching, so the
-- feature can default to on (and a Slack account added later can be polled)
-- without replaying the owner's reaction history as commands (FEAT-03).
-- Empty = never seeded. Deliberately a stamp, not "the ledger is empty": an
-- owner who has never reacted has an empty ledger too, and their first real
-- reaction must dispatch, not be swallowed as history.
ALTER TABLE slack_accounts ADD COLUMN reaction_commands_seeded_at TEXT NOT NULL DEFAULT '';

-- Backfill: an account with ANY ledger row has already been polled by the
-- feature (seeded by the enable hook, or dispatching for real), so its history
-- is closed — stamp it, or its first post-upgrade poll would record every
-- reaction placed since its last poll as history instead of a command.
-- Residual, accepted: an account that had the feature on but never accrued a
-- ledger row (the owner never reacted) stays unstamped and is seeded by its
-- first post-upgrade poll — at most one poll interval of reactions.
UPDATE slack_accounts
   SET reaction_commands_seeded_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE EXISTS (SELECT 1 FROM reaction_commands rc WHERE rc.account_id = slack_accounts.id);

-- +goose Down
ALTER TABLE slack_accounts DROP COLUMN reaction_commands_seeded_at;
