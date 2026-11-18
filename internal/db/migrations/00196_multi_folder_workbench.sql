-- +goose NO TRANSACTION
-- +goose Up
-- Multi-folder workbench (spec docs/superpowers/specs/2026-11-18-multi-folder-workbench-design.md §4,
-- board #2003).
--
-- 1. workbench_folders: the folders of a workbench, one live row per path
--    globally (NOCASE: APFS), names unique per bench among live rows.
--    Backfill: one row per workbench from projects.folder_path, position 0,
--    named after its last path component. A bench whose folder is another
--    spelling of an older bench's (bound before CreateWorkbench compared
--    NOCASE) gets its row removed, so the live-path index never fails here.
-- 2. terminal_sessions.workbench_folder_id (backfilled with the bench's only
--    folder) and parent_session_id; targets.workbench_folder_id (NULL = the
--    home folder).
-- 3. owner_asks: kind gains 'folder', doc_folder_id (NULL = the home folder;
--    doc_path stays relative to its folder). First rebuild of owner_asks.
-- 4. review_reviewer_threads and workbench_pr_states gain workbench_folder_id
--    in their primary keys (backfilled with the home folder), so two folders
--    with the same branch never share a thread or a PR state.
-- 5. workbench_folder_declines, session_messages, session_outside_touches.
-- 6. The workbench document index keys gain the folder, rekeyed in place
--    (wbdoc:<project>:<rel> -> wbdoc:<project>:<home folder>:<rel>) in
--    kb_documents, kb_chunks.doc_id and kb_dirty: entries indexed from a
--    privacy-protected folder (an explicit trigger) are never rebuilt by the
--    daemon, so they must survive. kb_fts is keyed by chunk rowid and the
--    kb_chunks_au trigger rewrites it with the same text.
--
-- owner_asks is the parent of ON DELETE CASCADE / SET NULL children (spec
-- reviews, marks, questions, thread findings, previous_ask_id), and
-- review_reviewer_threads carries a delete trigger, so foreign keys are OFF
-- around the rebuilds (a DROP fires no cascade; a DROP never fires a
-- trigger; kb_documents.id changes under its chunks). The pragma cannot change inside a transaction; everything between
-- is one BEGIN IMMEDIATE … COMMIT in one goose statement, so a failure
-- part-way leaves every table as it was (00150's pattern).
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE workbench_folders (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    folder_path  TEXT NOT NULL,
    position     INTEGER NOT NULL,
    added_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    added_by     TEXT NOT NULL CHECK (added_by IN ('owner','agent_suggestion')),
    removed_at   TEXT,
    name         TEXT NOT NULL
);
INSERT INTO workbench_folders (workbench_id, folder_path, position, added_at, added_by, removed_at, name)
SELECT p.id, p.folder_path, 0, p.created_at, 'owner',
    CASE WHEN EXISTS (SELECT 1 FROM projects q WHERE q.id < p.id AND q.folder_path = p.folder_path COLLATE NOCASE)
         THEN strftime('%Y-%m-%dT%H:%M:%SZ','now') END,
    COALESCE(NULLIF(substr(p.folder_path, length(rtrim(p.folder_path, replace(p.folder_path, '/', ''))) + 1), ''),
             p.folder_path)
FROM projects p ORDER BY p.id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_workbench_folders_live_path ON workbench_folders(folder_path COLLATE NOCASE) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_workbench_folders_live_name ON workbench_folders(workbench_id, name COLLATE NOCASE) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workbench_folders_bench ON workbench_folders(workbench_id, position);

ALTER TABLE terminal_sessions ADD COLUMN workbench_folder_id INTEGER REFERENCES workbench_folders(id) ON DELETE SET NULL;
ALTER TABLE terminal_sessions ADD COLUMN parent_session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL;
UPDATE terminal_sessions SET workbench_folder_id =
    (SELECT f.id FROM workbench_folders f WHERE f.workbench_id = terminal_sessions.project_id)
WHERE project_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_parent ON terminal_sessions(parent_session_id);

ALTER TABLE targets ADD COLUMN workbench_folder_id INTEGER REFERENCES workbench_folders(id) ON DELETE SET NULL;

CREATE TABLE owner_asks_new (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id       INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id       INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    target_id        INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    kind             TEXT NOT NULL CHECK(kind IN ('review','check','question','folder')),
    title            TEXT NOT NULL CHECK(title != ''),
    summary          TEXT NOT NULL DEFAULT '',
    changes          TEXT NOT NULL DEFAULT '',
    payload          TEXT NOT NULL DEFAULT '{}',
    doc_path         TEXT NOT NULL DEFAULT '',
    doc_snapshot     TEXT NOT NULL DEFAULT '',
    previous_ask_id  INTEGER REFERENCES owner_asks(id) ON DELETE SET NULL,
    status           TEXT NOT NULL DEFAULT 'open'
                     CHECK(status IN ('open','answered','delivered','withdrawn')),
    withdrawn_reason TEXT NOT NULL DEFAULT '' CHECK(withdrawn_reason IN ('','agent','superseded')),
    answer           TEXT NOT NULL DEFAULT '',
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    answered_at      TEXT NOT NULL DEFAULT '',
    delivered_at     TEXT NOT NULL DEFAULT '',
    level            TEXT NOT NULL DEFAULT 'full' CHECK (level IN ('quick','full')),
    origin           TEXT NOT NULL DEFAULT 'agent' CHECK (origin IN ('agent','chat')),
    chat_asked_at    TEXT NOT NULL DEFAULT '',
    withdrawn_at     TEXT NOT NULL DEFAULT '',
    automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL,
    doc_type         TEXT NOT NULL DEFAULT '',
    doc_folder_id    INTEGER REFERENCES workbench_folders(id) ON DELETE SET NULL,
    CHECK ((kind = 'review') = (doc_path != '')),
    CHECK ((status IN ('answered','delivered')) = (answer != ''))
);
INSERT INTO owner_asks_new (id, project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path,
    doc_snapshot, previous_ask_id, status, withdrawn_reason, answer, created_at, answered_at, delivered_at, level,
    origin, chat_asked_at, withdrawn_at, automation_run_id, doc_type)
SELECT id, project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path,
    doc_snapshot, previous_ask_id, status, withdrawn_reason, answer, created_at, answered_at, delivered_at, level,
    origin, chat_asked_at, withdrawn_at, automation_run_id, doc_type
FROM owner_asks;
DELETE FROM sqlite_sequence WHERE name = 'owner_asks_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'owner_asks_new', seq FROM sqlite_sequence WHERE name = 'owner_asks';
DROP TABLE owner_asks;
ALTER TABLE owner_asks_new RENAME TO owner_asks;
CREATE INDEX IF NOT EXISTS idx_owner_asks_project ON owner_asks(project_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_owner_asks_session ON owner_asks(session_id);

CREATE TABLE review_reviewer_threads_new (
  project_id          INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workbench_folder_id INTEGER NOT NULL REFERENCES workbench_folders(id) ON DELETE CASCADE,
  branch              TEXT NOT NULL CHECK (branch != ''),
  conversation_id     INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (project_id, workbench_folder_id, branch)
);
INSERT INTO review_reviewer_threads_new (project_id, workbench_folder_id, branch, conversation_id, created_at)
SELECT t.project_id, f.id, t.branch, t.conversation_id, t.created_at
FROM review_reviewer_threads t JOIN workbench_folders f ON f.workbench_id = t.project_id;
DROP TABLE review_reviewer_threads;
ALTER TABLE review_reviewer_threads_new RENAME TO review_reviewer_threads;
CREATE TRIGGER IF NOT EXISTS review_reviewer_threads_ad AFTER DELETE ON review_reviewer_threads
BEGIN
  DELETE FROM chat_conversations WHERE id = OLD.conversation_id AND context_type = 'review_reviewer';
END;

CREATE TABLE workbench_pr_states_new (
    project_id          INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    workbench_folder_id INTEGER NOT NULL REFERENCES workbench_folders(id) ON DELETE CASCADE,
    ref                 TEXT NOT NULL,
    state               TEXT NOT NULL CHECK(state IN ('merged','open','closed','none','unknown')),
    pr_number           INTEGER,
    title               TEXT NOT NULL DEFAULT '',
    additions           INTEGER,
    deletions           INTEGER,
    merged_at           TEXT NOT NULL DEFAULT '',
    checked_at          TEXT NOT NULL,
    PRIMARY KEY (project_id, workbench_folder_id, ref)
);
INSERT INTO workbench_pr_states_new (project_id, workbench_folder_id, ref, state, pr_number, title, additions,
    deletions, merged_at, checked_at)
SELECT s.project_id, f.id, s.ref, s.state, s.pr_number, s.title, s.additions, s.deletions, s.merged_at, s.checked_at
FROM workbench_pr_states s JOIN workbench_folders f ON f.workbench_id = s.project_id;
DROP TABLE workbench_pr_states;
ALTER TABLE workbench_pr_states_new RENAME TO workbench_pr_states;

CREATE TABLE workbench_folder_declines (
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    folder_path  TEXT NOT NULL COLLATE NOCASE,
    declined_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (workbench_id, folder_path)
);

CREATE TABLE session_messages (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    workbench_id      INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    from_session_id   INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    to_session_id     INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    kind              TEXT NOT NULL CHECK (kind IN ('message','finished','failure')),
    text              TEXT NOT NULL,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    state             TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','delivering','delivered','failed')),
    reason            TEXT NOT NULL DEFAULT '',
    delivered_at      TEXT,
    prompt_cleared_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_session_messages_state ON session_messages(state);
CREATE INDEX IF NOT EXISTS idx_session_messages_to ON session_messages(to_session_id, state);

CREATE TABLE session_outside_touches (
    session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    repo_root  TEXT NOT NULL,
    touches    INTEGER NOT NULL DEFAULT 0,
    nudged_at  TEXT,
    quiet      INTEGER NOT NULL DEFAULT 0 CHECK (quiet IN (0,1)),
    PRIMARY KEY (session_id, repo_root)
);

-- wbdoc:<project>:<rel> -> wbdoc:<project>:<folder>:<rel>, the folder being
-- the bench's only row (lowest position).
CREATE TEMP TABLE wbdoc_rekey AS
SELECT d.id AS old_id,
       'wbdoc:' || f.workbench_id || ':' || f.id || ':' || substr(d.id, 7 + instr(substr(d.id, 7), ':')) AS new_id
FROM kb_documents d JOIN workbench_folders f ON f.id = (
    SELECT f2.id FROM workbench_folders f2
    WHERE f2.workbench_id = CAST(substr(d.id, 7, instr(substr(d.id, 7), ':') - 1) AS INTEGER)
    ORDER BY f2.position, f2.id LIMIT 1)
WHERE d.id LIKE 'wbdoc:%' AND instr(substr(d.id, 7), ':') > 1;
UPDATE kb_chunks SET doc_id = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_chunks.doc_id)
WHERE doc_id IN (SELECT old_id FROM wbdoc_rekey);
UPDATE kb_documents SET id = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_documents.id)
WHERE id IN (SELECT old_id FROM wbdoc_rekey);
UPDATE kb_dirty SET key = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_dirty.key)
WHERE source = 'project_doc' AND key IN (SELECT old_id FROM wbdoc_rekey);
DROP TABLE wbdoc_rekey;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- Rows the old shape cannot hold go first, with foreign keys on so their
-- cascades and the thread trigger run: folder asks (their children and the
-- previous_ask_id links follow), and the reviewer threads, PR states and
-- workbench documents of any folder but a bench's home folder (db.HomeFolder:
-- the live row on projects.folder_path, else the lowest position), whose old
-- keys would collide. Then the rebuilds back, as in Up, in one transaction
-- inside the pragmas; the home folder's documents get their old keys back.
-- +goose StatementBegin
BEGIN IMMEDIATE;
DELETE FROM owner_asks WHERE kind = 'folder';
DELETE FROM review_reviewer_threads WHERE workbench_folder_id IS NOT (SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id WHERE f.workbench_id = review_reviewer_threads.project_id
    ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id LIMIT 1);
DELETE FROM workbench_pr_states WHERE workbench_folder_id IS NOT (SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id WHERE f.workbench_id = workbench_pr_states.project_id
    ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id LIMIT 1);
CREATE TEMP TABLE wbdoc_unkey AS
SELECT d.id AS new_id,
       CAST(substr(d.id, 7, instr(substr(d.id, 7), ':') - 1) AS INTEGER) AS project_id,
       substr(d.id, 7 + instr(substr(d.id, 7), ':')) AS folder_rel
FROM kb_documents d WHERE d.id LIKE 'wbdoc:%' AND instr(substr(d.id, 7), ':') > 1;
DELETE FROM kb_documents WHERE id IN (SELECT new_id FROM wbdoc_unkey u
    WHERE CAST(substr(u.folder_rel, 1, instr(u.folder_rel, ':') - 1) AS INTEGER) IS NOT (SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id WHERE f.workbench_id = u.project_id
    ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id LIMIT 1));
DELETE FROM kb_dirty WHERE source = 'project_doc' AND key LIKE 'wbdoc:%' AND key NOT IN (SELECT id FROM kb_documents);
DROP TABLE wbdoc_unkey;
COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

-- wbdoc:<project>:<folder>:<rel> -> wbdoc:<project>:<rel>.
CREATE TEMP TABLE wbdoc_rekey AS
SELECT id AS old_id, 'wbdoc:' || pid || ':' || substr(rest, instr(rest, ':') + 1) AS new_id
FROM (SELECT id, substr(id, 7, instr(substr(id, 7), ':') - 1) AS pid, substr(id, 7 + instr(substr(id, 7), ':')) AS rest
      FROM kb_documents WHERE id LIKE 'wbdoc:%' AND instr(substr(id, 7), ':') > 1)
WHERE instr(rest, ':') > 1;
UPDATE kb_chunks SET doc_id = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_chunks.doc_id)
WHERE doc_id IN (SELECT old_id FROM wbdoc_rekey);
UPDATE kb_documents SET id = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_documents.id)
WHERE id IN (SELECT old_id FROM wbdoc_rekey);
UPDATE kb_dirty SET key = (SELECT new_id FROM wbdoc_rekey WHERE old_id = kb_dirty.key)
WHERE source = 'project_doc' AND key IN (SELECT old_id FROM wbdoc_rekey);
DROP TABLE wbdoc_rekey;

DROP TABLE session_outside_touches;
DROP TABLE session_messages;
DROP TABLE workbench_folder_declines;

CREATE TABLE workbench_pr_states_old (
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    ref         TEXT NOT NULL,
    state       TEXT NOT NULL CHECK(state IN ('merged','open','closed','none','unknown')),
    pr_number   INTEGER,
    title       TEXT NOT NULL DEFAULT '',
    additions   INTEGER,
    deletions   INTEGER,
    merged_at   TEXT NOT NULL DEFAULT '',
    checked_at  TEXT NOT NULL,
    PRIMARY KEY (project_id, ref)
);
INSERT INTO workbench_pr_states_old (project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at)
SELECT project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at FROM workbench_pr_states;
DROP TABLE workbench_pr_states;
ALTER TABLE workbench_pr_states_old RENAME TO workbench_pr_states;

CREATE TABLE review_reviewer_threads_old (
  project_id      INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  branch          TEXT NOT NULL CHECK (branch != ''),
  conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (project_id, branch)
);
INSERT INTO review_reviewer_threads_old (project_id, branch, conversation_id, created_at)
SELECT project_id, branch, conversation_id, created_at FROM review_reviewer_threads;
DROP TABLE review_reviewer_threads;
ALTER TABLE review_reviewer_threads_old RENAME TO review_reviewer_threads;
CREATE TRIGGER IF NOT EXISTS review_reviewer_threads_ad AFTER DELETE ON review_reviewer_threads
BEGIN
  DELETE FROM chat_conversations WHERE id = OLD.conversation_id AND context_type = 'review_reviewer';
END;

CREATE TABLE owner_asks_old (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id       INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id       INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    target_id        INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    kind             TEXT NOT NULL CHECK(kind IN ('review','check','question')),
    title            TEXT NOT NULL CHECK(title != ''),
    summary          TEXT NOT NULL DEFAULT '',
    changes          TEXT NOT NULL DEFAULT '',
    payload          TEXT NOT NULL DEFAULT '{}',
    doc_path         TEXT NOT NULL DEFAULT '',
    doc_snapshot     TEXT NOT NULL DEFAULT '',
    previous_ask_id  INTEGER REFERENCES owner_asks(id) ON DELETE SET NULL,
    status           TEXT NOT NULL DEFAULT 'open'
                     CHECK(status IN ('open','answered','delivered','withdrawn')),
    withdrawn_reason TEXT NOT NULL DEFAULT '' CHECK(withdrawn_reason IN ('','agent','superseded')),
    answer           TEXT NOT NULL DEFAULT '',
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    answered_at      TEXT NOT NULL DEFAULT '',
    delivered_at     TEXT NOT NULL DEFAULT '',
    level            TEXT NOT NULL DEFAULT 'full' CHECK (level IN ('quick','full')),
    origin           TEXT NOT NULL DEFAULT 'agent' CHECK (origin IN ('agent','chat')),
    chat_asked_at    TEXT NOT NULL DEFAULT '',
    withdrawn_at     TEXT NOT NULL DEFAULT '',
    automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL,
    doc_type         TEXT NOT NULL DEFAULT '',
    CHECK ((kind = 'review') = (doc_path != '')),
    CHECK ((status IN ('answered','delivered')) = (answer != ''))
);
INSERT INTO owner_asks_old (id, project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path,
    doc_snapshot, previous_ask_id, status, withdrawn_reason, answer, created_at, answered_at, delivered_at, level,
    origin, chat_asked_at, withdrawn_at, automation_run_id, doc_type)
SELECT id, project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path,
    doc_snapshot, previous_ask_id, status, withdrawn_reason, answer, created_at, answered_at, delivered_at, level,
    origin, chat_asked_at, withdrawn_at, automation_run_id, doc_type
FROM owner_asks;
DELETE FROM sqlite_sequence WHERE name = 'owner_asks_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'owner_asks_old', seq FROM sqlite_sequence WHERE name = 'owner_asks';
DROP TABLE owner_asks;
ALTER TABLE owner_asks_old RENAME TO owner_asks;
CREATE INDEX IF NOT EXISTS idx_owner_asks_project ON owner_asks(project_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_owner_asks_session ON owner_asks(session_id);

ALTER TABLE targets DROP COLUMN workbench_folder_id;
DROP INDEX IF EXISTS idx_terminal_sessions_parent;
ALTER TABLE terminal_sessions DROP COLUMN parent_session_id;
ALTER TABLE terminal_sessions DROP COLUMN workbench_folder_id;

DROP TABLE workbench_folders;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
