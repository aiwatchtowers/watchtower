-- +goose Up
-- The independent reviewer beside Branch review (board #1025, phase 3): one
-- thread per branch of a workbench. `branch` is the round's branch (#1012)
-- when set, else the folder's checked-out branch; a detached HEAD keys by
-- `session:<id>`. The conversation is a `chat_conversations` row of context
-- type `review_reviewer`. The Desktop is the only writer.
CREATE TABLE IF NOT EXISTS review_reviewer_threads (
  project_id      INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  branch          TEXT NOT NULL CHECK (branch != ''),
  conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (project_id, branch)
);

-- The reviewer reads and quotes the folder's code, so its conversation never
-- outlives its thread row: a deleted workbench (cascade) takes it along.
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS review_reviewer_threads_ad AFTER DELETE ON review_reviewer_threads
BEGIN
  DELETE FROM chat_conversations WHERE id = OLD.conversation_id AND context_type = 'review_reviewer';
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS review_reviewer_threads_ad;
DROP TABLE IF EXISTS review_reviewer_threads;
