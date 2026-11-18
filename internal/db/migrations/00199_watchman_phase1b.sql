-- +goose Up
-- Watchman phase 1b (spec §9.1 Store): the learner's relabel pass flags each
-- precedent. is_decision / parked are NULL (not flagged yet; counts as a
-- candidate), 0 or 1; flags_at marks a row the pass already tried, even when
-- it left both flags NULL. handed counts the decisions of a backtest category
-- the twin handed to the owner (not scored).
ALTER TABLE watchman_precedents ADD COLUMN is_decision INTEGER;
ALTER TABLE watchman_precedents ADD COLUMN parked INTEGER;
ALTER TABLE watchman_precedents ADD COLUMN flags_at TEXT;
ALTER TABLE watchman_backtest_rows ADD COLUMN handed INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE watchman_backtest_rows DROP COLUMN handed;
ALTER TABLE watchman_precedents DROP COLUMN flags_at;
ALTER TABLE watchman_precedents DROP COLUMN parked;
ALTER TABLE watchman_precedents DROP COLUMN is_decision;
