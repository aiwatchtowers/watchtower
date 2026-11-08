-- +goose Up
-- Big-branch review (board #1025): one cached AI description per overview
-- chapter, so a Refresh redoes only the chapters whose files changed.
-- part_hash = sha256 of the chapter key, its files' (path, old blob, new blob),
-- the agent's notes on them and the prompt id + version. Pruned after 30 days
-- on write.
CREATE TABLE review_overview_parts (
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  part_hash  TEXT NOT NULL,
  json       TEXT NOT NULL,
  model      TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (project_id, part_hash)
);

-- The commit the round's snapshot was taken at (git rev-parse HEAD of the
-- session folder, or the branch tip a branch round read); '' for a round
-- made before this migration, which then gets no lane attribution.
ALTER TABLE review_rounds ADD COLUMN head_sha TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE review_rounds DROP COLUMN head_sha;
DROP TABLE IF EXISTS review_overview_parts;
