-- +goose Up
CREATE TABLE review_notes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  tree_sha   TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('note','chapter')),
  ord        INTEGER NOT NULL,
  path       TEXT NOT NULL DEFAULT '',
  start_line INTEGER NOT NULL DEFAULT 0,
  end_line   INTEGER NOT NULL DEFAULT 0,
  quote      TEXT NOT NULL DEFAULT '',
  text       TEXT NOT NULL,
  paths_json TEXT NOT NULL DEFAULT '[]',
  core       INTEGER NOT NULL DEFAULT 0 CHECK (core IN (0,1)),
  why        TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX review_notes_session ON review_notes(project_id, session_id, kind, ord);

CREATE TABLE review_overviews (
  project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  tree_sha    TEXT NOT NULL,
  base_sha    TEXT NOT NULL,
  intent_hash TEXT NOT NULL,
  json        TEXT NOT NULL,
  model       TEXT NOT NULL DEFAULT '',
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (project_id, tree_sha, base_sha, intent_hash)
);

CREATE TABLE review_reverts (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  hunk_id  TEXT NOT NULL,
  path     TEXT NOT NULL,
  header   TEXT NOT NULL,
  patch    TEXT NOT NULL,
  at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE (round_id, hunk_id)
);

CREATE TABLE review_lessons (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id         INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  lens               TEXT NOT NULL,
  text               TEXT NOT NULL,
  source_comment_ids TEXT NOT NULL DEFAULT '[]',
  status             TEXT NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','accepted','dismissed')),
  created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  decided_at         TEXT
);

-- +goose Down
DROP TABLE review_lessons;
DROP TABLE review_reverts;
DROP TABLE review_overviews;
DROP TABLE review_notes;
