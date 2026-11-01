-- +goose Up
-- When the relay first listed a linked phone as holding this hub in a slot
-- (Go hub plan 2 Task 10, relay "Vouched hubs"): the phone vouched for the hub
-- and put it into its slot. NULL = not yet (`hub phones` transport
-- "pending"). A timestamp, no content. A re-link writes the row anew (NULL);
-- the next account state stamps it again. A hub that later finds itself in
-- no slot while a phone carries a stamp reports vouch_revoked.
ALTER TABLE devices ADD COLUMN relay_admitted_at REAL;

-- +goose Down
ALTER TABLE devices DROP COLUMN relay_admitted_at;
