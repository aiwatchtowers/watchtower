-- +goose Up
-- Jira status/assignee history (board #185): the company keeps no worklogs,
-- so "time spent" is read from the status history. Three account-scoped
-- tables; every timestamp is in FormatJiraTime's fixed-width UTC form (00092).
--
-- jira_issue_changelog: one row per changed field of one change history.
-- For field 'status' *_value is the status id and *_string its name; for
-- 'assignee' *_value is the Atlassian account id and *_string the display
-- name. No CHECK on field, so a later field needs no table recreation. An
-- issue's rows are replaced as a whole on every fetch (the API returns its
-- full field-filtered history).
CREATE TABLE IF NOT EXISTS jira_issue_changelog (
    account_id          INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key           TEXT NOT NULL,
    history_id          TEXT NOT NULL,
    field               TEXT NOT NULL,
    from_value          TEXT NOT NULL DEFAULT '',
    from_string         TEXT NOT NULL DEFAULT '',
    to_value            TEXT NOT NULL DEFAULT '',
    to_string           TEXT NOT NULL DEFAULT '',
    author_account_id   TEXT NOT NULL DEFAULT '',
    author_display_name TEXT NOT NULL DEFAULT '',
    changed_at          TEXT NOT NULL,
    PRIMARY KEY (account_id, issue_key, history_id, field)
);
CREATE INDEX IF NOT EXISTS idx_jira_issue_changelog_issue ON jira_issue_changelog(account_id, issue_key, changed_at);

-- jira_changelog_sync: per-issue cursor. issue_updated_at is the issue's
-- updated_at the stored changelog belongs to; an issue whose current
-- updated_at differs, or that has no row, is due for a fetch.
CREATE TABLE IF NOT EXISTS jira_changelog_sync (
    account_id       INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key        TEXT NOT NULL,
    issue_updated_at TEXT NOT NULL,
    synced_at        TEXT NOT NULL,
    PRIMARY KEY (account_id, issue_key)
);

-- jira_linked_issues: a slim snapshot of issues linked from synced issues
-- that are not themselves in jira_issues (other boards). Kept out of
-- jira_issues on purpose: its many readers (dashboards, inbox, memory,
-- knowledge index) must not start seeing other teams' issues. fetch_error is
-- set for a key the site would not return (no access, deleted, moved).
CREATE TABLE IF NOT EXISTS jira_linked_issues (
    account_id            INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    key                   TEXT NOT NULL,
    id                    TEXT NOT NULL DEFAULT '',
    project_key           TEXT NOT NULL DEFAULT '',
    summary               TEXT NOT NULL DEFAULT '',
    issue_type            TEXT NOT NULL DEFAULT '',
    status                TEXT NOT NULL DEFAULT '',
    status_category       TEXT NOT NULL DEFAULT '',
    assignee_account_id   TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL DEFAULT '',
    updated_at            TEXT NOT NULL DEFAULT '',
    resolved_at           TEXT NOT NULL DEFAULT '',
    fetch_error           TEXT NOT NULL DEFAULT '',
    synced_at             TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, key)
);

-- The linked-issue queries (candidates, prune, link expansion) look links up
-- by either end; jira_issue_links had only its (account_id, id) key.
CREATE INDEX IF NOT EXISTS idx_jira_issue_links_target ON jira_issue_links(account_id, target_key);
CREATE INDEX IF NOT EXISTS idx_jira_issue_links_source ON jira_issue_links(account_id, source_key);

-- +goose Down
DROP INDEX IF EXISTS idx_jira_issue_links_source;
DROP INDEX IF EXISTS idx_jira_issue_links_target;
DROP TABLE IF EXISTS jira_linked_issues;
DROP TABLE IF EXISTS jira_changelog_sync;
DROP INDEX IF EXISTS idx_jira_issue_changelog_issue;
DROP TABLE IF EXISTS jira_issue_changelog;
