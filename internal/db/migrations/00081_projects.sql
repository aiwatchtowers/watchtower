-- +goose Up
-- Projects POC (spec docs/superpowers/specs/2026-09-29-project-board-poc-design.md §3):
-- a folder-bound project, its sources, the documents Claude Code attaches and
-- the owner<->agent comments on targets and documents. targets.project_id puts
-- a target on exactly one project board; a project target never reaches a
-- non-board reader (PROJ-01, docs/inventory/projects.md).
-- AUTOINCREMENT on projects/project_sources/project_documents/project_comments
-- (I3): their ids are agent-facing (the "watchtower document <id>" prompt
-- line, the `mcp --project N` session, tool args such as source_id) and outlive a single session, so a
-- plain rowid recycled after a delete would silently rebind a stale hook,
-- MCP registration or prompt reference to whatever new row took the old id.
CREATE TABLE projects (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    folder_path TEXT NOT NULL UNIQUE,          -- absolute, symlinks resolved
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE TABLE project_documents (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    rel_path   TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),  -- re-attach bumps it ("revised")
    UNIQUE(project_id, rel_path)
);
CREATE INDEX idx_project_documents_target ON project_documents(target_id);

CREATE TABLE project_comments (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    document_id    INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
    parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
    author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
    agent_label    TEXT NOT NULL DEFAULT '',
    body           TEXT NOT NULL,
    anchor_quote   TEXT NOT NULL DEFAULT '',
    anchor_prefix  TEXT NOT NULL DEFAULT '',
    anchor_suffix  TEXT NOT NULL DEFAULT '',
    anchor_heading TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at        TEXT NOT NULL DEFAULT '',
    CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
CREATE INDEX idx_project_comments_project  ON project_comments(project_id, created_at);
CREATE INDEX idx_project_comments_target   ON project_comments(target_id);
CREATE INDEX idx_project_comments_document ON project_comments(document_id);
CREATE INDEX idx_project_comments_parent   ON project_comments(parent_id);

ALTER TABLE targets ADD COLUMN project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE;
CREATE INDEX idx_targets_project ON targets(project_id);

-- +goose Down
-- Project targets go with their projects: left behind without project_id they
-- would surface as personal targets in every reader.
DELETE FROM targets WHERE project_id IS NOT NULL;
DROP INDEX IF EXISTS idx_targets_project;
ALTER TABLE targets DROP COLUMN project_id;
DROP TABLE IF EXISTS project_comments;
DROP TABLE IF EXISTS project_documents;
DROP TABLE IF EXISTS project_sources;
DROP TABLE IF EXISTS projects;
