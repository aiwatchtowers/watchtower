-- +goose Up
-- Slack Full (#1709, plan B Task 2).
--
-- slack_accounts.client_id: the Slack app (client id) the account's token was
-- issued through; '' = connected before this migration, backfilled once from
-- the id the build bakes or the retired shared id (A17). Written by every
-- connect (db.SetSlackAccountApp) and by db.BackfillSlackClientIDs, which only
-- fills rows still at ''.
ALTER TABLE slack_accounts ADD COLUMN client_id TEXT NOT NULL DEFAULT '';
-- slack_accounts.app_id: the Slack App ID from oauth.v2.access; '' = unknown.
ALTER TABLE slack_accounts ADD COLUMN app_id TEXT NOT NULL DEFAULT '';
-- slack_accounts.refresh_token_expires_at: RFC 3339 UTC expiry of a rotated
-- token's refresh token; '' = no rotation.
ALTER TABLE slack_accounts ADD COLUMN refresh_token_expires_at TEXT NOT NULL DEFAULT '';

-- slack_app_setups: one row per team whose own Slack app this install set up
-- (`slack app create|adopt`, A5). "Connected" is derived from an ok
-- slack_accounts row with the same client id, never stored. link_written =
-- the connect link is on the app's About page; install_requested_at = RFC 3339
-- UTC when Slack reported an admin approval request, '' = none.
CREATE TABLE IF NOT EXISTS slack_app_setups (
    team_id              TEXT PRIMARY KEY,
    team_name            TEXT NOT NULL DEFAULT '',
    app_id               TEXT NOT NULL,
    client_id            TEXT NOT NULL,
    link_written         INTEGER NOT NULL DEFAULT 0,
    install_requested_at TEXT NOT NULL DEFAULT '',
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
);

-- +goose Down
DROP TABLE IF EXISTS slack_app_setups;
ALTER TABLE slack_accounts DROP COLUMN refresh_token_expires_at;
ALTER TABLE slack_accounts DROP COLUMN app_id;
ALTER TABLE slack_accounts DROP COLUMN client_id;
