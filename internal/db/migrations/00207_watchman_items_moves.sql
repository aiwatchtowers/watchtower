-- +goose Up
-- Watchman phase 2 (final review fix wave 2): how many times a review_code
-- item's diff moved after its decision (new commits, a Refresh, a repoint).
-- Counted apart from attempts, so failures and moves never share one cap;
-- the third move parks the review for the owner. NULL = none.
ALTER TABLE watchman_items ADD COLUMN moves INTEGER;

-- +goose Down
ALTER TABLE watchman_items DROP COLUMN moves;
