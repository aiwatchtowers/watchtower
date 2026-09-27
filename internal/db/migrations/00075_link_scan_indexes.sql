-- +goose Up
-- doc_links detection (internal/doclinks.ScanSources) walks jira_issues and
-- jira_comments by their synced_at high-water in batches of 1000; without an
-- index every batch would scan the whole table.
CREATE INDEX IF NOT EXISTS idx_jira_issues_synced ON jira_issues(synced_at);
CREATE INDEX IF NOT EXISTS idx_jira_comments_synced ON jira_comments(synced_at);

-- +goose Down
DROP INDEX IF EXISTS idx_jira_comments_synced;
DROP INDEX IF EXISTS idx_jira_issues_synced;
