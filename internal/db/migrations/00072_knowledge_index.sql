-- +goose Up
-- Knowledge search (spec docs/superpowers/specs/2026-09-26-knowledge-search-design.md).
-- A derived, rebuildable index (KB-01): nothing here is a source of truth.
CREATE TABLE IF NOT EXISTS kb_documents (
    id            TEXT PRIMARY KEY,
    source        TEXT NOT NULL,
    title         TEXT NOT NULL DEFAULT '',
    doc_time      TEXT NOT NULL DEFAULT '',
    doc_time_unix REAL NOT NULL DEFAULT 0,
    link          TEXT NOT NULL DEFAULT '',
    anchor_json   TEXT NOT NULL DEFAULT '{}',
    meta          TEXT NOT NULL DEFAULT '',
    content_hash  TEXT NOT NULL DEFAULT '',
    chunk_count   INTEGER NOT NULL DEFAULT 0,
    indexed_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_kb_documents_source_time ON kb_documents(source, doc_time_unix);

CREATE TABLE IF NOT EXISTS kb_chunks (
    id      INTEGER PRIMARY KEY,
    doc_id  TEXT NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    title   TEXT NOT NULL DEFAULT '',
    body    TEXT NOT NULL,
    meta    TEXT NOT NULL DEFAULT '',
    anchor  TEXT NOT NULL DEFAULT '',
    UNIQUE(doc_id, idx)
);

CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
    title, body, meta,
    content='kb_chunks', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_ai AFTER INSERT ON kb_chunks BEGIN
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_ad AFTER DELETE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_au AFTER UPDATE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS kb_sources (
    source             TEXT PRIMARY KEY,
    cursor             TEXT NOT NULL DEFAULT '',
    last_reconciled_at TEXT NOT NULL DEFAULT '',
    updated_at         TEXT NOT NULL DEFAULT ''
);

-- +goose Down
DROP TRIGGER IF EXISTS kb_chunks_au;
DROP TRIGGER IF EXISTS kb_chunks_ad;
DROP TRIGGER IF EXISTS kb_chunks_ai;
DROP TABLE IF EXISTS kb_fts;
DROP TABLE IF EXISTS kb_chunks;
DROP TABLE IF EXISTS kb_sources;
DROP TABLE IF EXISTS kb_documents;
