-- +goose Up
-- Big-branch review (board #1025): one cached AI description per chapter of
-- the overview, keyed by the chapter's content hash (its key, its files'
-- blobs, its own agent notes, the prompt version), so a Refresh redoes only
-- the chapters whose files changed. Rows older than 30 days are pruned on
-- write.
CREATE TABLE IF NOT EXISTS review_overview_parts (
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
