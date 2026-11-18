-- +goose Up
-- The phone's `chat` grant (iPhone chat spec §4.5, D9): the phone may use the
-- main AI chat over the relay. On by default for the phones already linked
-- and for new ones (owner decision, ask #1340); the owner turns it off per
-- phone. Approving a chat action also needs permissions_allowed.
ALTER TABLE devices ADD COLUMN chat_allowed INTEGER NOT NULL DEFAULT 1;

-- +goose Down
ALTER TABLE devices DROP COLUMN chat_allowed;
