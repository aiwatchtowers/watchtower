-- +goose Up
-- Linear connector raw store (docs/superpowers/specs/2026-10-15-linear-integration-design.md §4.1).
-- One linear_accounts row per Linear workspace; every other table is scoped by
-- account_id. Issues are keyed by Linear's UUID: the human key ("ENG-12") moves
-- when an issue changes team, so it is a mutable column with previous_keys.
CREATE TABLE IF NOT EXISTS linear_accounts (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    org_id                   TEXT NOT NULL DEFAULT '',
    url_key                  TEXT NOT NULL DEFAULT '',
    org_name                 TEXT NOT NULL DEFAULT '',
    label                    TEXT NOT NULL DEFAULT '',
    status                   TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error                    TEXT NOT NULL DEFAULT '',
    enabled                  INTEGER NOT NULL DEFAULT 1,
    owner_user_id            TEXT NOT NULL DEFAULT '',
    owner_email              TEXT NOT NULL DEFAULT '',
    owner_display_name       TEXT NOT NULL DEFAULT '',
    memory_last_extracted_ts REAL NOT NULL DEFAULT 0,
    ideas_floor              TEXT NOT NULL DEFAULT '',
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_linear_accounts_org ON linear_accounts(org_id) WHERE org_id != '';

CREATE TABLE IF NOT EXISTS linear_teams (
    account_id  INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id          TEXT NOT NULL,
    key         TEXT NOT NULL DEFAULT '',
    name        TEXT NOT NULL DEFAULT '',
    is_selected INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_teams_key ON linear_teams(key);

CREATE TABLE IF NOT EXISTS linear_sync_state (
    account_id     INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    team_id        TEXT NOT NULL,
    watermark      TEXT NOT NULL DEFAULT '',
    last_synced_at TEXT NOT NULL DEFAULT '',
    last_error     TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, team_id)
);

CREATE TABLE IF NOT EXISTS linear_issues (
    account_id            INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                    TEXT NOT NULL,
    key                   TEXT NOT NULL,
    previous_keys         TEXT NOT NULL DEFAULT '[]',
    team_id               TEXT NOT NULL DEFAULT '',
    team_key              TEXT NOT NULL DEFAULT '',
    title                 TEXT NOT NULL DEFAULT '',
    description_text      TEXT NOT NULL DEFAULT '',
    state_name            TEXT NOT NULL DEFAULT '',
    state_type            TEXT NOT NULL DEFAULT '',
    status_category       TEXT NOT NULL DEFAULT 'todo',
    state_changed_at      TEXT NOT NULL DEFAULT '',
    assignee_id           TEXT NOT NULL DEFAULT '',
    assignee_email        TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '',
    assignee_slack_id     TEXT NOT NULL DEFAULT '',
    creator_id            TEXT NOT NULL DEFAULT '',
    creator_email         TEXT NOT NULL DEFAULT '',
    creator_display_name  TEXT NOT NULL DEFAULT '',
    creator_slack_id      TEXT NOT NULL DEFAULT '',
    priority              INTEGER NOT NULL DEFAULT 0,
    estimate              REAL,
    due_date              TEXT NOT NULL DEFAULT '',
    cycle_id              TEXT NOT NULL DEFAULT '',
    project_id            TEXT NOT NULL DEFAULT '',
    parent_id             TEXT NOT NULL DEFAULT '',
    labels                TEXT NOT NULL DEFAULT '[]',
    url                   TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL DEFAULT '',
    updated_at            TEXT NOT NULL DEFAULT '',
    completed_at          TEXT NOT NULL DEFAULT '',
    canceled_at           TEXT NOT NULL DEFAULT '',
    raw_json              TEXT NOT NULL DEFAULT '{}',
    synced_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    is_deleted            INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_issues_key ON linear_issues(key);
CREATE INDEX IF NOT EXISTS idx_linear_issues_team ON linear_issues(account_id, team_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_assignee ON linear_issues(assignee_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_assignee_status ON linear_issues(assignee_slack_id, status_category);
CREATE INDEX IF NOT EXISTS idx_linear_issues_status_cat ON linear_issues(status_category);
CREATE INDEX IF NOT EXISTS idx_linear_issues_cycle ON linear_issues(cycle_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_project ON linear_issues(project_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_updated ON linear_issues(updated_at);
CREATE INDEX IF NOT EXISTS idx_linear_issues_due ON linear_issues(due_date);
CREATE INDEX IF NOT EXISTS idx_linear_issues_synced ON linear_issues(synced_at);

CREATE TABLE IF NOT EXISTS linear_comments (
    account_id          INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                  TEXT NOT NULL,
    issue_id            TEXT NOT NULL,
    issue_key           TEXT NOT NULL DEFAULT '',
    author_id           TEXT NOT NULL DEFAULT '',
    author_display_name TEXT NOT NULL DEFAULT '',
    body_text           TEXT NOT NULL DEFAULT '',
    mentioned_user_ids  TEXT NOT NULL DEFAULT '[]',
    created_at          TEXT NOT NULL DEFAULT '',
    updated_at          TEXT NOT NULL DEFAULT '',
    synced_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_comments_issue_author ON linear_comments(issue_key, author_id);
CREATE INDEX IF NOT EXISTS idx_linear_comments_created ON linear_comments(created_at);
CREATE INDEX IF NOT EXISTS idx_linear_comments_synced ON linear_comments(synced_at);

CREATE TABLE IF NOT EXISTS linear_issue_history (
    account_id         INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                 TEXT NOT NULL,
    field              TEXT NOT NULL CHECK (field IN ('status','assignee')),
    issue_id           TEXT NOT NULL,
    from_value         TEXT NOT NULL DEFAULT '',
    from_string        TEXT NOT NULL DEFAULT '',
    to_value           TEXT NOT NULL DEFAULT '',
    to_string          TEXT NOT NULL DEFAULT '',
    actor_id           TEXT NOT NULL DEFAULT '',
    actor_display_name TEXT NOT NULL DEFAULT '',
    changed_at         TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id, field)
);
CREATE INDEX IF NOT EXISTS idx_linear_history_issue ON linear_issue_history(account_id, issue_id, changed_at);

CREATE TABLE IF NOT EXISTS linear_cycles (
    account_id   INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id           TEXT NOT NULL,
    team_id      TEXT NOT NULL DEFAULT '',
    number       INTEGER NOT NULL DEFAULT 0,
    name         TEXT NOT NULL DEFAULT '',
    starts_at    TEXT NOT NULL DEFAULT '',
    ends_at      TEXT NOT NULL DEFAULT '',
    completed_at TEXT NOT NULL DEFAULT '',
    progress     REAL NOT NULL DEFAULT 0,
    synced_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);

CREATE TABLE IF NOT EXISTS linear_projects (
    account_id  INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id          TEXT NOT NULL,
    name        TEXT NOT NULL DEFAULT '',
    state       TEXT NOT NULL DEFAULT '',
    progress    REAL NOT NULL DEFAULT 0,
    target_date TEXT NOT NULL DEFAULT '',
    lead_id     TEXT NOT NULL DEFAULT '',
    url         TEXT NOT NULL DEFAULT '',
    synced_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);

-- issue_id blocks/relates to/duplicates related_issue_id ("A blocks B").
CREATE TABLE IF NOT EXISTS linear_relations (
    account_id       INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id               TEXT NOT NULL,
    issue_id         TEXT NOT NULL,
    related_issue_id TEXT NOT NULL,
    type             TEXT NOT NULL,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_relations_related ON linear_relations(account_id, related_issue_id, type);
CREATE INDEX IF NOT EXISTS idx_linear_relations_issue ON linear_relations(account_id, issue_id);

-- Linear user UUIDs are global, so the map is not account-scoped (the
-- jira_user_map precedent).
CREATE TABLE IF NOT EXISTS linear_user_map (
    linear_user_id   TEXT PRIMARY KEY,
    email            TEXT NOT NULL DEFAULT '',
    display_name     TEXT NOT NULL DEFAULT '',
    slack_user_id    TEXT NOT NULL DEFAULT '',
    match_method     TEXT NOT NULL DEFAULT '',
    match_confidence REAL NOT NULL DEFAULT 0,
    resolved_at      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_linear_user_map_slack ON linear_user_map(slack_user_id);

-- +goose Down
DROP TABLE IF EXISTS linear_user_map;
DROP TABLE IF EXISTS linear_relations;
DROP TABLE IF EXISTS linear_projects;
DROP TABLE IF EXISTS linear_cycles;
DROP TABLE IF EXISTS linear_issue_history;
DROP TABLE IF EXISTS linear_comments;
DROP TABLE IF EXISTS linear_issues;
DROP TABLE IF EXISTS linear_sync_state;
DROP TABLE IF EXISTS linear_teams;
DROP TABLE IF EXISTS linear_accounts;
