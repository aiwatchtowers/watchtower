-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Jira multi-account (sub-project 3 of 3 of the multi-account initiative).
-- One row per connected Atlassian site. Unlike Slack (namespaced string ids),
-- Jira follows the Google composite-PK route: issue keys ("PROJ-123") are
-- user-visible and flow through regexes, prompts, targets.source_id, memory
-- jira: refs and MCP tool args — prefixing them would break all of that.
-- Instead every site-scoped table gains an account_id column and a composite
-- PK; readers that look up by bare key keep working (cross-site key collision
-- is a documented v1 limitation, the mail:/gmailthread: precedent).

-- 1. Account table (site identity moves here from config.yaml's
--    jira.cloud_id / site_url / user_display_name, which become frozen).
CREATE TABLE IF NOT EXISTS jira_accounts (
    id                            INTEGER PRIMARY KEY AUTOINCREMENT,
    cloud_id                      TEXT NOT NULL DEFAULT '',
    site_url                      TEXT NOT NULL DEFAULT '',
    site_name                     TEXT NOT NULL DEFAULT '',
    label                         TEXT NOT NULL DEFAULT '',
    status                        TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error                         TEXT NOT NULL DEFAULT '',
    enabled                       INTEGER NOT NULL DEFAULT 1,
    memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0,  -- per-account memory extraction watermark (was workspace.memory_jira_last_extracted_ts)
    created_at                    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Seed account #1 when legacy Jira data exists (cloud_id/site_url live in
--    config.yaml, which SQL can't see — ensureLegacyJiraAccount fills them in
--    Go, and also handles token-only installs with no synced data).
--    The condition must cover EVERY table steps 3-10 re-parent to
--    account_id = 1: those copies are unconditional, so a narrower seed (say,
--    boards/issues only) would leave rows pointing at an account that does not
--    exist — and the next `jira add` would mint id 1 and silently adopt another
--    site's custom fields / releases.
--    The NOT EXISTS guard makes the seed idempotent: jira_accounts is created
--    with IF NOT EXISTS, so a re-run of this statement (a goose version line
--    replayed after a partial NO TRANSACTION apply) must not mint a second,
--    empty account that `jira accounts` would then show as a ghost site.
INSERT INTO jira_accounts (cloud_id, site_url, site_name, memory_jira_last_extracted_ts)
SELECT '', '', '',
       COALESCE((SELECT memory_jira_last_extracted_ts FROM workspace LIMIT 1), 0)
WHERE NOT EXISTS (SELECT 1 FROM jira_accounts)
  AND (EXISTS (SELECT 1 FROM jira_boards)
    OR EXISTS (SELECT 1 FROM jira_issues)
    OR EXISTS (SELECT 1 FROM jira_sprints)
    OR EXISTS (SELECT 1 FROM jira_issue_links)
    OR EXISTS (SELECT 1 FROM jira_custom_fields)
    OR EXISTS (SELECT 1 FROM jira_board_field_map)
    OR EXISTS (SELECT 1 FROM jira_sync_state)
    OR EXISTS (SELECT 1 FROM jira_releases)
    OR COALESCE((SELECT memory_jira_last_extracted_ts FROM workspace LIMIT 1), 0) > 0);

-- 3. jira_boards: PK becomes (account_id, id) — raw board ids are small
--    integers and collide across sites.
CREATE TABLE jira_boards_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL, name TEXT NOT NULL, project_key TEXT NOT NULL DEFAULT '',
    board_type TEXT NOT NULL DEFAULT '', is_selected INTEGER NOT NULL DEFAULT 0,
    issue_count INTEGER NOT NULL DEFAULT 0, synced_at TEXT NOT NULL DEFAULT '',
    raw_columns_json TEXT NOT NULL DEFAULT '',
    raw_config_json TEXT NOT NULL DEFAULT '',
    llm_profile_json TEXT NOT NULL DEFAULT '',
    workflow_summary TEXT NOT NULL DEFAULT '',
    user_overrides_json TEXT NOT NULL DEFAULT '',
    config_hash TEXT NOT NULL DEFAULT '',
    profile_generated_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);
INSERT INTO jira_boards_new
SELECT 1, id, name, project_key, board_type, is_selected, issue_count, synced_at,
       raw_columns_json, raw_config_json, llm_profile_json, workflow_summary,
       user_overrides_json, config_hash, profile_generated_at
FROM jira_boards;
DROP TABLE jira_boards;
ALTER TABLE jira_boards_new RENAME TO jira_boards;

-- 4. jira_custom_fields: PK becomes (account_id, id) — "customfield_NNNNN"
--    ids collide across sites.
CREATE TABLE jira_custom_fields_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    field_type TEXT NOT NULL,
    items_type TEXT NOT NULL DEFAULT '',
    is_useful INTEGER NOT NULL DEFAULT 0,
    usage_hint TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);
INSERT INTO jira_custom_fields_new
SELECT 1, id, name, field_type, items_type, is_useful, usage_hint, synced_at
FROM jira_custom_fields;
DROP TABLE jira_custom_fields;
ALTER TABLE jira_custom_fields_new RENAME TO jira_custom_fields;

-- 5. jira_board_field_map: PK becomes (account_id, board_id, field_id).
CREATE TABLE jira_board_field_map_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    board_id INTEGER NOT NULL,
    field_id TEXT NOT NULL,
    role TEXT NOT NULL,
    PRIMARY KEY (account_id, board_id, field_id)
);
INSERT INTO jira_board_field_map_new
SELECT 1, board_id, field_id, role FROM jira_board_field_map;
DROP TABLE jira_board_field_map;
ALTER TABLE jira_board_field_map_new RENAME TO jira_board_field_map;

-- 6. jira_issues: PK becomes (account_id, key). Bare-key readers keep
--    working; a key shared by two sites is a documented v1 ambiguity.
CREATE TABLE jira_issues_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    key TEXT NOT NULL, id TEXT NOT NULL DEFAULT '', project_key TEXT NOT NULL,
    board_id INTEGER,
    summary TEXT NOT NULL, description_text TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '', issue_type_category TEXT NOT NULL DEFAULT '',
    is_bug INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL, status_category TEXT NOT NULL,
    status_category_changed_at TEXT NOT NULL DEFAULT '',
    assignee_account_id TEXT NOT NULL DEFAULT '', assignee_email TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '', assignee_slack_id TEXT NOT NULL DEFAULT '',
    reporter_account_id TEXT NOT NULL DEFAULT '', reporter_email TEXT NOT NULL DEFAULT '',
    reporter_display_name TEXT NOT NULL DEFAULT '', reporter_slack_id TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '', story_points REAL,
    due_date TEXT NOT NULL DEFAULT '', sprint_id INTEGER, sprint_name TEXT NOT NULL DEFAULT '',
    epic_key TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '[]', components TEXT NOT NULL DEFAULT '[]',
    fix_versions TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '', custom_fields_json TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, key)
);
INSERT INTO jira_issues_new
SELECT 1, key, id, project_key, board_id, summary, description_text,
       issue_type, issue_type_category, is_bug, status, status_category,
       status_category_changed_at,
       assignee_account_id, assignee_email, assignee_display_name, assignee_slack_id,
       reporter_account_id, reporter_email, reporter_display_name, reporter_slack_id,
       priority, story_points, due_date, sprint_id, sprint_name, epic_key,
       labels, components, fix_versions,
       created_at, updated_at, resolved_at, raw_json, custom_fields_json,
       synced_at, is_deleted
FROM jira_issues;
DROP TABLE jira_issues;
ALTER TABLE jira_issues_new RENAME TO jira_issues;
CREATE INDEX IF NOT EXISTS idx_jira_issues_project ON jira_issues(project_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee ON jira_issues(assignee_account_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_status_cat ON jira_issues(status_category);
CREATE INDEX IF NOT EXISTS idx_jira_issues_sprint ON jira_issues(sprint_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_epic ON jira_issues(epic_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_updated ON jira_issues(updated_at);
CREATE INDEX IF NOT EXISTS idx_jira_issues_due ON jira_issues(due_date);
CREATE INDEX IF NOT EXISTS idx_jira_issues_board ON jira_issues(board_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_slack ON jira_issues(assignee_slack_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_status ON jira_issues(assignee_slack_id, status_category);
-- The pre-00049 PK was `key` alone, so bare-key lookups rode its implicit
-- unique index. Under the composite PK that index leads with account_id, so
-- `WHERE key = ?` degrades to a full scan — and bare-key readers are exactly
-- what this migration preserves (GetJiraIssueByKey, JiraIssueExists,
-- SyncJiraTargetStatuses, the MCP get_jira_issue tool). Restore the index.
CREATE INDEX IF NOT EXISTS idx_jira_issues_key ON jira_issues(key);

-- 7. jira_sprints: PK becomes (account_id, id).
CREATE TABLE jira_sprints_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL, board_id INTEGER NOT NULL, name TEXT NOT NULL,
    state TEXT NOT NULL, goal TEXT NOT NULL DEFAULT '',
    start_date TEXT NOT NULL DEFAULT '', end_date TEXT NOT NULL DEFAULT '',
    complete_date TEXT NOT NULL DEFAULT '', synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);
INSERT INTO jira_sprints_new
SELECT 1, id, board_id, name, state, goal, start_date, end_date, complete_date, synced_at
FROM jira_sprints;
DROP TABLE jira_sprints;
ALTER TABLE jira_sprints_new RENAME TO jira_sprints;

-- 8. jira_issue_links: PK becomes (account_id, id).
CREATE TABLE jira_issue_links_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL, source_key TEXT NOT NULL, target_key TEXT NOT NULL,
    link_type TEXT NOT NULL, synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);
INSERT INTO jira_issue_links_new
SELECT 1, id, source_key, target_key, link_type, synced_at FROM jira_issue_links;
DROP TABLE jira_issue_links;
ALTER TABLE jira_issue_links_new RENAME TO jira_issue_links;

-- 9. jira_sync_state: PK becomes (account_id, project_key) — two sites
--    sharing a project key must not clobber each other's watermark.
CREATE TABLE jira_sync_state_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    project_key TEXT NOT NULL, last_synced_at TEXT NOT NULL DEFAULT '',
    issues_synced INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '',
    last_error_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, project_key)
);
INSERT INTO jira_sync_state_new
SELECT 1, project_key, last_synced_at, issues_synced, last_error, last_error_at
FROM jira_sync_state;
DROP TABLE jira_sync_state;
ALTER TABLE jira_sync_state_new RENAME TO jira_sync_state;

-- 10. jira_releases: PK becomes (account_id, id), UNIQUE gains account_id.
CREATE TABLE jira_releases_new (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL,
    project_key TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    release_date TEXT NOT NULL DEFAULT '',
    released INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id),
    UNIQUE(account_id, project_key, name)
);
INSERT INTO jira_releases_new
SELECT 1, id, project_key, name, description, release_date, released, archived, synced_at
FROM jira_releases;
DROP TABLE jira_releases;
ALTER TABLE jira_releases_new RENAME TO jira_releases;

-- jira_user_map is intentionally NOT account-scoped: Atlassian account ids
-- are globally unique. jira_slack_links is intentionally NOT account-scoped:
-- keys detected in Slack text are site-ambiguous by nature (documented v1).

-- 11. Retire the workspace watermark (moved to jira_accounts).
ALTER TABLE workspace DROP COLUMN memory_jira_last_extracted_ts;

PRAGMA foreign_keys = ON;

-- +goose Down
--
-- LOSSY BY CONSTRUCTION for a genuinely multi-account install: the pre-00049
-- tables have no account dimension, so every step below keeps only
-- account_id = 1 and DROPS the other sites' boards, issues, sprints, links,
-- sync state, fields and releases. Nothing can preserve them — the target
-- schema cannot represent two sites. Down is an escape hatch for a workspace
-- that has not yet connected a second site; anyone else must re-sync after
-- rolling back. Pinned by TestMigration00049DownDropsOtherAccounts.
PRAGMA foreign_keys = OFF;
ALTER TABLE workspace ADD COLUMN memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0;
UPDATE workspace SET memory_jira_last_extracted_ts =
    COALESCE((SELECT memory_jira_last_extracted_ts FROM jira_accounts WHERE id = 1), 0);
CREATE TABLE jira_releases_old (
    id INTEGER NOT NULL,
    project_key TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    release_date TEXT NOT NULL DEFAULT '',
    released INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id),
    UNIQUE(project_key, name)
);
INSERT OR IGNORE INTO jira_releases_old
SELECT id, project_key, name, description, release_date, released, archived, synced_at
FROM jira_releases WHERE account_id = 1;
DROP TABLE jira_releases;
ALTER TABLE jira_releases_old RENAME TO jira_releases;
CREATE TABLE jira_sync_state_old (
    project_key TEXT PRIMARY KEY, last_synced_at TEXT NOT NULL DEFAULT '',
    issues_synced INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '',
    last_error_at TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO jira_sync_state_old
SELECT project_key, last_synced_at, issues_synced, last_error, last_error_at
FROM jira_sync_state WHERE account_id = 1;
DROP TABLE jira_sync_state;
ALTER TABLE jira_sync_state_old RENAME TO jira_sync_state;
CREATE TABLE jira_issue_links_old (
    id TEXT PRIMARY KEY, source_key TEXT NOT NULL, target_key TEXT NOT NULL,
    link_type TEXT NOT NULL, synced_at TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO jira_issue_links_old
SELECT id, source_key, target_key, link_type, synced_at
FROM jira_issue_links WHERE account_id = 1;
DROP TABLE jira_issue_links;
ALTER TABLE jira_issue_links_old RENAME TO jira_issue_links;
CREATE TABLE jira_sprints_old (
    id INTEGER PRIMARY KEY, board_id INTEGER NOT NULL, name TEXT NOT NULL,
    state TEXT NOT NULL, goal TEXT NOT NULL DEFAULT '',
    start_date TEXT NOT NULL DEFAULT '', end_date TEXT NOT NULL DEFAULT '',
    complete_date TEXT NOT NULL DEFAULT '', synced_at TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO jira_sprints_old
SELECT id, board_id, name, state, goal, start_date, end_date, complete_date, synced_at
FROM jira_sprints WHERE account_id = 1;
DROP TABLE jira_sprints;
ALTER TABLE jira_sprints_old RENAME TO jira_sprints;
CREATE TABLE jira_issues_old (
    key TEXT PRIMARY KEY, id TEXT NOT NULL DEFAULT '', project_key TEXT NOT NULL,
    board_id INTEGER,
    summary TEXT NOT NULL, description_text TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '', issue_type_category TEXT NOT NULL DEFAULT '',
    is_bug INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL, status_category TEXT NOT NULL,
    status_category_changed_at TEXT NOT NULL DEFAULT '',
    assignee_account_id TEXT NOT NULL DEFAULT '', assignee_email TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '', assignee_slack_id TEXT NOT NULL DEFAULT '',
    reporter_account_id TEXT NOT NULL DEFAULT '', reporter_email TEXT NOT NULL DEFAULT '',
    reporter_display_name TEXT NOT NULL DEFAULT '', reporter_slack_id TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '', story_points REAL,
    due_date TEXT NOT NULL DEFAULT '', sprint_id INTEGER, sprint_name TEXT NOT NULL DEFAULT '',
    epic_key TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '[]', components TEXT NOT NULL DEFAULT '[]',
    fix_versions TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '', custom_fields_json TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO jira_issues_old
SELECT key, id, project_key, board_id, summary, description_text,
       issue_type, issue_type_category, is_bug, status, status_category,
       status_category_changed_at,
       assignee_account_id, assignee_email, assignee_display_name, assignee_slack_id,
       reporter_account_id, reporter_email, reporter_display_name, reporter_slack_id,
       priority, story_points, due_date, sprint_id, sprint_name, epic_key,
       labels, components, fix_versions,
       created_at, updated_at, resolved_at, raw_json, custom_fields_json,
       synced_at, is_deleted
FROM jira_issues WHERE account_id = 1;
DROP TABLE jira_issues;
ALTER TABLE jira_issues_old RENAME TO jira_issues;
CREATE INDEX IF NOT EXISTS idx_jira_issues_project ON jira_issues(project_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee ON jira_issues(assignee_account_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_status_cat ON jira_issues(status_category);
CREATE INDEX IF NOT EXISTS idx_jira_issues_sprint ON jira_issues(sprint_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_epic ON jira_issues(epic_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_updated ON jira_issues(updated_at);
CREATE INDEX IF NOT EXISTS idx_jira_issues_due ON jira_issues(due_date);
CREATE INDEX IF NOT EXISTS idx_jira_issues_board ON jira_issues(board_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_slack ON jira_issues(assignee_slack_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_status ON jira_issues(assignee_slack_id, status_category);
CREATE TABLE jira_board_field_map_old (
    board_id INTEGER NOT NULL,
    field_id TEXT NOT NULL,
    role TEXT NOT NULL,
    PRIMARY KEY (board_id, field_id)
);
INSERT OR IGNORE INTO jira_board_field_map_old
SELECT board_id, field_id, role FROM jira_board_field_map WHERE account_id = 1;
DROP TABLE jira_board_field_map;
ALTER TABLE jira_board_field_map_old RENAME TO jira_board_field_map;
CREATE TABLE jira_custom_fields_old (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    field_type TEXT NOT NULL,
    items_type TEXT NOT NULL DEFAULT '',
    is_useful INTEGER NOT NULL DEFAULT 0,
    usage_hint TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO jira_custom_fields_old
SELECT id, name, field_type, items_type, is_useful, usage_hint, synced_at
FROM jira_custom_fields WHERE account_id = 1;
DROP TABLE jira_custom_fields;
ALTER TABLE jira_custom_fields_old RENAME TO jira_custom_fields;
CREATE TABLE jira_boards_old (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, project_key TEXT NOT NULL DEFAULT '',
    board_type TEXT NOT NULL DEFAULT '', is_selected INTEGER NOT NULL DEFAULT 0,
    issue_count INTEGER NOT NULL DEFAULT 0, synced_at TEXT NOT NULL DEFAULT '',
    raw_columns_json TEXT NOT NULL DEFAULT '',
    raw_config_json TEXT NOT NULL DEFAULT '',
    llm_profile_json TEXT NOT NULL DEFAULT '',
    workflow_summary TEXT NOT NULL DEFAULT '',
    user_overrides_json TEXT NOT NULL DEFAULT '',
    config_hash TEXT NOT NULL DEFAULT '',
    profile_generated_at TEXT NOT NULL DEFAULT ''
);
INSERT OR IGNORE INTO jira_boards_old
SELECT id, name, project_key, board_type, is_selected, issue_count, synced_at,
       raw_columns_json, raw_config_json, llm_profile_json, workflow_summary,
       user_overrides_json, config_hash, profile_generated_at
FROM jira_boards WHERE account_id = 1;
DROP TABLE jira_boards;
ALTER TABLE jira_boards_old RENAME TO jira_boards;
DROP TABLE IF EXISTS jira_accounts;
PRAGMA foreign_keys = ON;
