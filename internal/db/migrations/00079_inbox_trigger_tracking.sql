-- +goose Up
-- When the sync last saw this event's start_time or end_time change (the
-- sync pass's own synced_at), '' when it never has. The inbox's
-- calendar_time_change trigger keys on it: synced_at is rewritten on every
-- pass and updated_at is the provider's stamp, which always precedes the pass
-- that fetched it, so neither can tell a rescheduled meeting apart.
ALTER TABLE calendar_events ADD COLUMN time_changed_at TEXT NOT NULL DEFAULT '';

-- Per attendee, when the sync last saw their response_status change: a JSON
-- object {lower-cased email: synced_at of that pass}, '{}' when none has.
-- The inbox resolves a calendar_time_change item only once the owner's RSVP
-- was given after the reschedule (owner decision 2026-09-29, INBOX-02).
ALTER TABLE calendar_events ADD COLUMN rsvp_changed TEXT NOT NULL DEFAULT '{}';

-- The inbox reads the owner's own comments per issue key (jira_assigned
-- own-comment suppression and Jira auto-resolve). idx_jira_comments_issue
-- leads with account_id, which that read does not bind, so it scanned the
-- whole table.
CREATE INDEX IF NOT EXISTS idx_jira_comments_issue_author ON jira_comments(issue_key, author_account_id);

-- +goose Down
DROP INDEX IF EXISTS idx_jira_comments_issue_author;
ALTER TABLE calendar_events DROP COLUMN rsvp_changed;
ALTER TABLE calendar_events DROP COLUMN time_changed_at;
