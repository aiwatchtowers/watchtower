-- +goose Up
-- Inbox redesign phase 4 (#1076): the Gmail sync also fetches the owner's own
-- sent mail, so a thread the owner replied to can close. A connected account
-- runs a one-time sent catch-up over the existing window; this stamp records
-- when it finished ('' = not yet), so it runs once per account.
ALTER TABLE google_accounts ADD COLUMN gmail_sent_catchup_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE google_accounts DROP COLUMN gmail_sent_catchup_at;
