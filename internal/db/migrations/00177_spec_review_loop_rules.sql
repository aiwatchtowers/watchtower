-- +goose Up
-- The rules an author loop runs under (spec 2026-11-08 spec-review-discuss
-- §1): 0 = the rules of 2026-10-26 (a cap of 3 rounds), 2 = the loop goes on
-- while the author's fixes hold, up to a fuse of 8. A loop keeps the rules it
-- started with, so rows from before this migration keep 0.
ALTER TABLE spec_reviews ADD COLUMN loop_rules INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE spec_reviews DROP COLUMN loop_rules;
