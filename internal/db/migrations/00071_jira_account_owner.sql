-- +goose Up
-- The connecting person's own Atlassian identity, from GET /rest/api/3/myself.
-- Feeds db.ResolveOwner's Jira rung and the owner's authoritative Jira id
-- (before this, the owner's Jira identity was only a fuzzy jira_user_map guess).
ALTER TABLE jira_accounts ADD COLUMN owner_account_id TEXT NOT NULL DEFAULT '';
ALTER TABLE jira_accounts ADD COLUMN owner_email TEXT NOT NULL DEFAULT '';
ALTER TABLE jira_accounts ADD COLUMN owner_display_name TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE jira_accounts DROP COLUMN owner_display_name;
ALTER TABLE jira_accounts DROP COLUMN owner_email;
ALTER TABLE jira_accounts DROP COLUMN owner_account_id;
