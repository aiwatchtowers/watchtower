-- +goose Up
-- External knowledge sources (spec docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md §4).
-- Source data, not derived: kb reindex rebuilds Confluence documents from
-- these tables without the network (KB-01 holds). Attachment binaries are
-- never stored (EXT-03); only extracted text in ext_documents.sections_json.
CREATE TABLE ext_sources (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  provider         TEXT NOT NULL CHECK (provider IN ('confluence')),
  jira_account_id  INTEGER REFERENCES jira_accounts(id) ON DELETE CASCADE,
  connection_id    INTEGER REFERENCES external_connections(id) ON DELETE CASCADE,
  container_key    TEXT NOT NULL,          -- space key
  container_ext_id TEXT NOT NULL DEFAULT '',-- space id (REST v2)
  container_name   TEXT NOT NULL DEFAULT '',
  enabled          INTEGER NOT NULL DEFAULT 1,
  page_cursor       TEXT NOT NULL DEFAULT '',  -- RFC3339 lastModified high-water
  comment_cursor    TEXT NOT NULL DEFAULT '',
  attachment_cursor TEXT NOT NULL DEFAULT '',
  page_token        TEXT NOT NULL DEFAULT '',  -- in-flight pagination token per stream
  comment_token     TEXT NOT NULL DEFAULT '',  --   (resume mid-backfill; cleared when
  attachment_token  TEXT NOT NULL DEFAULT '',  --    the stream's enumeration completes)
  backfill_done    INTEGER NOT NULL DEFAULT 0,
  last_reconcile_at TEXT NOT NULL DEFAULT '',
  last_synced_at   TEXT NOT NULL DEFAULT '',
  status           TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','error','needs_consent','revoked')),
  error            TEXT NOT NULL DEFAULT '',
  created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  CHECK ((jira_account_id IS NULL) != (connection_id IS NULL))
);
-- SQLite treats NULLs as distinct in UNIQUE, so one partial index per owner column.
CREATE UNIQUE INDEX idx_ext_sources_jira ON ext_sources(provider, jira_account_id, container_key)
  WHERE jira_account_id IS NOT NULL;
CREATE UNIQUE INDEX idx_ext_sources_conn ON ext_sources(provider, connection_id, container_key)
  WHERE connection_id IS NOT NULL;

CREATE TABLE ext_documents (
  source_id     INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id        TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('page','blogpost','attachment')),
  parent_ext_id TEXT NOT NULL DEFAULT '',
  title         TEXT NOT NULL DEFAULT '',
  url           TEXT NOT NULL DEFAULT '',
  version       INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'current',
  author_id     TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL DEFAULT '',
  modified_at   TEXT NOT NULL DEFAULT '',
  sections_json TEXT NOT NULL DEFAULT '[]',   -- [{"heading":..,"anchor":..,"text":..}]
  meta_json     TEXT NOT NULL DEFAULT '{}',
  media_type    TEXT NOT NULL DEFAULT '',
  size_bytes    INTEGER NOT NULL DEFAULT 0,
  extract_status TEXT NOT NULL DEFAULT 'ok'
      CHECK (extract_status IN ('ok','skipped_type','too_large','ocr_pending','ocr_unavailable','failed')),
  extract_attempts INTEGER NOT NULL DEFAULT 0,
  children_changed_at TEXT NOT NULL DEFAULT '',  -- a comment moved: re-render the page
  synced_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX idx_ext_documents_synced ON ext_documents(synced_at);
CREATE INDEX idx_ext_documents_parent ON ext_documents(source_id, parent_ext_id);

CREATE TABLE ext_comments (
  source_id    INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id       TEXT NOT NULL,
  page_ext_id  TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('footer','inline')),
  author_id    TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL DEFAULT '',
  version      INTEGER NOT NULL DEFAULT 0,
  body_text    TEXT NOT NULL DEFAULT '',
  anchor_text  TEXT NOT NULL DEFAULT '',
  resolved     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX idx_ext_comments_page ON ext_comments(source_id, page_ext_id);

CREATE TABLE ext_users (
  provider     TEXT NOT NULL,
  ext_user_id  TEXT NOT NULL,          -- Atlassian accountId for Confluence
  display_name TEXT NOT NULL DEFAULT '',
  email        TEXT NOT NULL DEFAULT '',
  fetched_at   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (provider, ext_user_id)
);

CREATE TABLE doc_links (
  from_kind TEXT NOT NULL,   -- 'confluence' | 'slack' | 'gmail' | 'jira'
  from_ref  TEXT NOT NULL,   -- kb-style ref of the mentioning document
  to_kind   TEXT NOT NULL,   -- 'jira_issue' | 'confluence_page'
  to_ref    TEXT NOT NULL,   -- 'PROJ-123' | '<cloud_id>:<page_id>'
  detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (from_kind, from_ref, to_kind, to_ref)
);
CREATE INDEX idx_doc_links_to ON doc_links(to_kind, to_ref);

CREATE TABLE ext_link_state (          -- doc_links detection watermark per scanned kind
  from_kind TEXT PRIMARY KEY,          -- 'slack' | 'gmail' | 'imap' | 'jira'
  cursor    TEXT NOT NULL DEFAULT ''   -- rowid / synced_at high-water, per kind
);

-- +goose Down
DROP TABLE IF EXISTS ext_link_state;
DROP TABLE IF EXISTS doc_links;
DROP TABLE IF EXISTS ext_users;
DROP TABLE IF EXISTS ext_comments;
DROP TABLE IF EXISTS ext_documents;
DROP INDEX IF EXISTS idx_ext_sources_conn;
DROP INDEX IF EXISTS idx_ext_sources_jira;
DROP TABLE IF EXISTS ext_sources;
