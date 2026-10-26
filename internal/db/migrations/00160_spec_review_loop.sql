-- +goose Up
-- Spec review author loop (#1121): the loop's state lives on the review row.
-- loop: '' = no loop (classic owner review), 'author' = the author is fixing
-- findings, 'owner' = the loop ended and the owner sees what is left.
-- replies / open_items / ledger are JSON written by the loop code.
ALTER TABLE spec_reviews ADD COLUMN loop TEXT NOT NULL DEFAULT '' CHECK (loop IN ('','author','owner'));
ALTER TABLE spec_reviews ADD COLUMN round INTEGER NOT NULL DEFAULT 0;
ALTER TABLE spec_reviews ADD COLUMN replies TEXT NOT NULL DEFAULT '';
ALTER TABLE spec_reviews ADD COLUMN open_items TEXT NOT NULL DEFAULT '';
ALTER TABLE spec_reviews ADD COLUMN ledger TEXT NOT NULL DEFAULT '';
ALTER TABLE spec_reviews ADD COLUMN loop_end TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE spec_reviews DROP COLUMN loop_end;
ALTER TABLE spec_reviews DROP COLUMN ledger;
ALTER TABLE spec_reviews DROP COLUMN open_items;
ALTER TABLE spec_reviews DROP COLUMN replies;
ALTER TABLE spec_reviews DROP COLUMN round;
ALTER TABLE spec_reviews DROP COLUMN loop;
