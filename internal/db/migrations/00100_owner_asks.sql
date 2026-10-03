-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Workbench owner asks (spec docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md
-- Part 2): the agent asks the owner to review a document, run a check or
-- answer questions, and the answer comes back to the session. Asks replace
-- attached documents and their anchored comments, which go here:
--
-- 1. owner_asks. Go writes open, withdrawn and delivered; the Desktop writes
--    only open -> answered (with answer and answered_at), guarded on
--    status = 'open'.
-- 2. Document comments and every reply under them are deleted, then
--    project_comments is rebuilt without document_id and the anchor_*
--    columns. projects/targets/project_comments are parents of
--    ON DELETE CASCADE children, hence PRAGMA foreign_keys = OFF around the
--    whole migration (NO TRANSACTION) rather than defer_foreign_keys (see the
--    00002 incident note in the add-migration skill). The replies are walked
--    explicitly, so the delete does not depend on the cascade firing. The
--    AUTOINCREMENT high-water mark is carried over: comment ids are
--    agent-facing (00081 I3), so a deleted document comment's id is never
--    handed out again.
-- 3. project_documents is dropped.
-- 4. The old index entries of attached documents (kb source project_doc) are
--    deleted, chunks first: the kb_chunks_ad trigger keeps kb_fts in step.
--    The next knowledge pass or `workbench resync` rebuilds the entries from
--    the folders under the new key format.

CREATE TABLE owner_asks (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id       INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id       INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    target_id        INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    kind             TEXT NOT NULL CHECK(kind IN ('review','check','question')),
    title            TEXT NOT NULL CHECK(title != ''),
    summary          TEXT NOT NULL DEFAULT '',
    changes          TEXT NOT NULL DEFAULT '',   -- review re-round: what changed, agent-written
    payload          TEXT NOT NULL DEFAULT '{}', -- JSON: focus[], questions[], checklist[]
    doc_path         TEXT NOT NULL DEFAULT '',   -- review only: rel path inside the folder
    doc_snapshot     TEXT NOT NULL DEFAULT '',   -- review only: file text at ask time
    previous_ask_id  INTEGER REFERENCES owner_asks(id) ON DELETE SET NULL,
    status           TEXT NOT NULL DEFAULT 'open'
                     CHECK(status IN ('open','answered','delivered','withdrawn')),
    withdrawn_reason TEXT NOT NULL DEFAULT '' CHECK(withdrawn_reason IN ('','agent','superseded')),
    answer           TEXT NOT NULL DEFAULT '',   -- JSON, Desktop-written
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    answered_at      TEXT NOT NULL DEFAULT '',
    delivered_at     TEXT NOT NULL DEFAULT '',
    CHECK ((kind = 'review') = (doc_path != '')),
    CHECK ((status IN ('answered','delivered')) = (answer != ''))
);
CREATE INDEX idx_owner_asks_project ON owner_asks(project_id, status, created_at);
CREATE INDEX idx_owner_asks_session ON owner_asks(session_id);

DELETE FROM project_comments WHERE id IN (
    WITH RECURSIVE doc_thread(id) AS (
        SELECT id FROM project_comments WHERE document_id IS NOT NULL
        UNION
        SELECT c.id FROM project_comments c JOIN doc_thread d ON c.parent_id = d.id
    )
    SELECT id FROM doc_thread
);

CREATE TABLE project_comments_new (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
    author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
    agent_label    TEXT NOT NULL DEFAULT '',
    body           TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at        TEXT NOT NULL DEFAULT '',
    CHECK (target_id IS NOT NULL OR parent_id IS NOT NULL)
);
INSERT INTO project_comments_new
    (id, project_id, target_id, parent_id, author, agent_label, body, status, created_at, read_at)
SELECT id, project_id, target_id, parent_id, author, agent_label, body, status, created_at, read_at
FROM project_comments;
DELETE FROM sqlite_sequence WHERE name = 'project_comments_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'project_comments_new', seq FROM sqlite_sequence WHERE name = 'project_comments';
DROP TABLE project_comments;
ALTER TABLE project_comments_new RENAME TO project_comments;
CREATE INDEX idx_project_comments_project ON project_comments(project_id, created_at);
CREATE INDEX idx_project_comments_target  ON project_comments(target_id);
CREATE INDEX idx_project_comments_parent  ON project_comments(parent_id);

DROP TABLE project_documents;

DELETE FROM kb_chunks WHERE doc_id IN (SELECT id FROM kb_documents WHERE source = 'project_doc');
DELETE FROM kb_documents WHERE source = 'project_doc';

PRAGMA foreign_keys = ON;

-- +goose Down
-- The Down restores the shapes only: project_documents comes back empty and
-- project_comments regains document_id and the anchor_* columns (target
-- comments keep their rows), but the deleted document comments and index
-- entries are not restored, and the asks are dropped.
PRAGMA foreign_keys = OFF;

DROP TABLE IF EXISTS owner_asks;

CREATE TABLE project_documents (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    rel_path   TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    origin     TEXT NOT NULL DEFAULT 'agent' CHECK(origin IN ('agent','import','owner')),
    UNIQUE(project_id, rel_path)
);
CREATE INDEX idx_project_documents_target ON project_documents(target_id);

CREATE TABLE project_comments_old (
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
INSERT INTO project_comments_old
    (id, project_id, target_id, parent_id, author, agent_label, body, status, created_at, read_at)
SELECT id, project_id, target_id, parent_id, author, agent_label, body, status, created_at, read_at
FROM project_comments;
DELETE FROM sqlite_sequence WHERE name = 'project_comments_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'project_comments_old', seq FROM sqlite_sequence WHERE name = 'project_comments';
DROP TABLE project_comments;
ALTER TABLE project_comments_old RENAME TO project_comments;
CREATE INDEX idx_project_comments_project  ON project_comments(project_id, created_at);
CREATE INDEX idx_project_comments_target   ON project_comments(target_id);
CREATE INDEX idx_project_comments_document ON project_comments(document_id);
CREATE INDEX idx_project_comments_parent   ON project_comments(parent_id);

PRAGMA foreign_keys = ON;
