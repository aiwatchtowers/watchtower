-- +goose Up
CREATE TABLE review_rounds (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id     INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  source         TEXT NOT NULL DEFAULT 'session' CHECK (source IN ('session','pr')),
  folder_root    TEXT NOT NULL,
  base_sha       TEXT NOT NULL,
  base_label     TEXT NOT NULL DEFAULT '',
  tree_sha       TEXT NOT NULL,
  prev_round_id  INTEGER REFERENCES review_rounds(id) ON DELETE SET NULL,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','sent','delivered')),
  mode           TEXT NOT NULL DEFAULT 'quick' CHECK (mode IN ('quick','deep')),
  phase          TEXT NOT NULL DEFAULT '',
  chapter_key    TEXT NOT NULL DEFAULT '',
  active_seconds INTEGER NOT NULL DEFAULT 0 CHECK (active_seconds >= 0),
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  sent_at        TEXT,
  delivered_at   TEXT
);
CREATE UNIQUE INDEX review_rounds_one_open ON review_rounds(session_id) WHERE status = 'open' AND session_id IS NOT NULL;
CREATE INDEX review_rounds_project ON review_rounds(project_id, id);

CREATE TABLE review_comments (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id       INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  path           TEXT,
  side           TEXT NOT NULL DEFAULT 'new' CHECK (side IN ('old','new')),
  start_line     INTEGER NOT NULL DEFAULT 0,
  end_line       INTEGER NOT NULL DEFAULT 0,
  quote          TEXT NOT NULL DEFAULT '',
  quote_prefix   TEXT NOT NULL DEFAULT '',
  quote_suffix   TEXT NOT NULL DEFAULT '',
  tree_sha       TEXT NOT NULL DEFAULT '',
  lens           TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','carried','resolved','outdated')),
  carried_from   INTEGER REFERENCES review_comments(id) ON DELETE SET NULL,
  agent_reply    TEXT NOT NULL DEFAULT '',
  agent_reply_at TEXT,
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX review_comments_round ON review_comments(round_id, id);

CREATE TABLE review_viewed (
  round_id    INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  path        TEXT NOT NULL,
  content_sha TEXT NOT NULL,
  PRIMARY KEY (round_id, path)
);

-- +goose Down
DROP TABLE review_viewed;
DROP TABLE review_comments;
DROP TABLE review_rounds;
