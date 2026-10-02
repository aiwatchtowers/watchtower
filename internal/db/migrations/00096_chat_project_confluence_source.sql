-- +goose Up
-- A chat project can pin a Confluence space (board #209): its pinned Slack
-- channels, Jira projects and Confluence spaces now steer search_knowledge
-- (the workbench scope, internal/tools/workbench_knowledge.go). SQLite cannot
-- alter a CHECK, so the table is recreated. Nothing references
-- chat_project_sources, so its DROP cascades nothing and no foreign_keys
-- toggle is needed.
CREATE TABLE chat_project_sources_new (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','confluence_space','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);
INSERT INTO chat_project_sources_new (id, project_id, kind, ref, label)
    SELECT id, project_id, kind, ref, label FROM chat_project_sources;
DROP TABLE chat_project_sources;
ALTER TABLE chat_project_sources_new RENAME TO chat_project_sources;

-- +goose Down
CREATE TABLE chat_project_sources_old (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);
INSERT INTO chat_project_sources_old (id, project_id, kind, ref, label)
    SELECT id, project_id, kind, ref, label FROM chat_project_sources
    WHERE kind != 'confluence_space';
DROP TABLE chat_project_sources;
ALTER TABLE chat_project_sources_old RENAME TO chat_project_sources;
