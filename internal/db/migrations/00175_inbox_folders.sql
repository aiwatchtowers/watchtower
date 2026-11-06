-- +goose Up
-- Inbox builder B: the Inbox menu's folders. The folder tables hold the
-- menu's arrangement only, never an item (STRIP-02); only the CLI writes
-- them, under a compare-and-set on inbox_folder_state.revision. No CHECK
-- changes on an existing table, so no table rebuild.
CREATE TABLE IF NOT EXISTS inbox_folders (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL CHECK (kind IN ('root','approvals','owner')),
    parent_id  INTEGER REFERENCES inbox_folders(id),
    slug       TEXT NOT NULL UNIQUE,
    title      TEXT NOT NULL,
    icon       TEXT NOT NULL DEFAULT '',
    position   INTEGER NOT NULL DEFAULT 0,
    hidden     INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0,1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    CHECK ((kind = 'root') = (parent_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_inbox_folders_one_root ON inbox_folders(kind) WHERE kind IN ('root','approvals');
CREATE INDEX IF NOT EXISTS idx_inbox_folders_parent ON inbox_folders(parent_id, position);

CREATE TABLE IF NOT EXISTS inbox_folder_state (
    id       INTEGER PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS inbox_folder_routes (
    automation_id INTEGER PRIMARY KEY REFERENCES automations(id) ON DELETE CASCADE,
    folder_id     INTEGER NOT NULL REFERENCES inbox_folders(id)
);

ALTER TABLE automation_outputs ADD COLUMN folder_id INTEGER REFERENCES inbox_folders(id) ON DELETE SET NULL;

-- An Inbox artifact's effective folder: its explicit folder, else its
-- automation's route, else the root. Read by the CLI and the Desktop alike.
CREATE VIEW IF NOT EXISTS inbox_artifact_folders AS
SELECT o.id AS output_id,
       COALESCE(o.folder_id, r.folder_id, (SELECT id FROM inbox_folders WHERE kind = 'root')) AS folder_id
FROM automation_outputs o LEFT JOIN inbox_folder_routes r ON r.automation_id = o.automation_id
WHERE o.kind = 'inbox';

INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position)
VALUES ('root', NULL, 'inbox', 'Inbox', '', 0);
INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position)
VALUES ('approvals', (SELECT id FROM inbox_folders WHERE kind = 'root'), 'needs-approval', 'Needs approval', '', 0);
INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1);

-- +goose Down
DROP VIEW IF EXISTS inbox_artifact_folders;
ALTER TABLE automation_outputs DROP COLUMN folder_id;
DROP TABLE IF EXISTS inbox_folder_routes;
DROP TABLE IF EXISTS inbox_folder_state;
DROP INDEX IF EXISTS idx_inbox_folders_parent;
DROP INDEX IF EXISTS idx_inbox_folders_one_root;
DROP TABLE IF EXISTS inbox_folders;
