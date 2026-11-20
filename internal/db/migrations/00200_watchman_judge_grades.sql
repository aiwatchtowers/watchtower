-- +goose Up
-- Watchman backtest graded by a judge (ask #1423): every hidden decision of
-- the twin is same (agree), acceptable or bad; strong is decided on bad, not
-- on agreement. wrong_high now counts bad decisions taken at high confidence.
-- rec_baseline is the share of the scored decisions where the owner picked
-- the option the agent marked recommended (informational).
ALTER TABLE watchman_backtest_rows ADD COLUMN acceptable INTEGER NOT NULL DEFAULT 0;
ALTER TABLE watchman_backtest_rows ADD COLUMN bad INTEGER NOT NULL DEFAULT 0;
ALTER TABLE watchman_backtest_rows ADD COLUMN rec_baseline REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE watchman_backtest_rows DROP COLUMN rec_baseline;
ALTER TABLE watchman_backtest_rows DROP COLUMN bad;
ALTER TABLE watchman_backtest_rows DROP COLUMN acceptable;
