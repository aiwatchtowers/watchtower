-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- HTML artifacts (board #535): chat_artifacts.kind gains 'html' — a
-- self-contained HTML page (a slide deck, a report) the Desktop renders in a
-- sandboxed web view with no network and no bridge.
--
-- SQLite has no ALTER CONSTRAINT, so this is the table-recreation dance.
-- chat_artifacts is not a parent (no table references it), but the pattern
-- stays the safe one: PRAGMA foreign_keys = OFF around the whole migration
-- (NO TRANSACTION). The table has no indexes beyond its UNIQUE constraint
-- and no triggers.

CREATE TABLE chat_artifacts_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kind            TEXT NOT NULL CHECK(kind IN ('document','table','email','slack','event','code','html')),
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    meta_json       TEXT NOT NULL DEFAULT '{}',
    edited          INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    UNIQUE(conversation_id, artifact_key, version)
);
INSERT INTO chat_artifacts_new (id, conversation_id, message_id, artifact_key, version, kind, title, content,
                                meta_json, edited, created_at)
SELECT id, conversation_id, message_id, artifact_key, version, kind, title, content,
       meta_json, edited, created_at
FROM chat_artifacts;
DROP TABLE chat_artifacts;
ALTER TABLE chat_artifacts_new RENAME TO chat_artifacts;

PRAGMA foreign_keys = ON;

-- +goose Down
-- An html version cannot live in the old table; it is kept as a document
-- (its source stays readable) rather than dropped.
PRAGMA foreign_keys = OFF;

CREATE TABLE chat_artifacts_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kind            TEXT NOT NULL CHECK(kind IN ('document','table','email','slack','event','code')),
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    meta_json       TEXT NOT NULL DEFAULT '{}',
    edited          INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    UNIQUE(conversation_id, artifact_key, version)
);
INSERT INTO chat_artifacts_old (id, conversation_id, message_id, artifact_key, version, kind, title, content,
                                meta_json, edited, created_at)
SELECT id, conversation_id, message_id, artifact_key, version,
       CASE WHEN kind = 'html' THEN 'document' ELSE kind END, title, content,
       meta_json, edited, created_at
FROM chat_artifacts;
DROP TABLE chat_artifacts;
ALTER TABLE chat_artifacts_old RENAME TO chat_artifacts;

PRAGMA foreign_keys = ON;
