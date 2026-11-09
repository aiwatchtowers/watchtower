-- +goose Up
-- The branch a round on the task branch's tip reviews (board #1012); '' for
-- a folder round. A plain start compares it with the branch the session
-- resolves to now, so a renamed ticket branch moves the open round.
ALTER TABLE review_rounds ADD COLUMN branch TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE review_rounds DROP COLUMN branch;
