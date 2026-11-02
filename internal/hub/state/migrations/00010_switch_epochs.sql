-- +goose Up
-- Why each epoch began, and until when a retired epoch's relay-lane keys are
-- accepted (Go hub plan 3 Task 20, relay sim rule 14 with the 7-day cap of
-- ask #843): an enum and a time only, no content. A row written before this
-- migration has neither; its retention is read from retired_at.
ALTER TABLE hub_epochs ADD COLUMN reason TEXT CHECK (reason IN ('age', 'cap', 'unlink', 'manual', 'transport_switch'));
ALTER TABLE hub_epochs ADD COLUMN retire_after REAL;
-- A phone whose relay entitlement lapsed while the hub stays on the relay
-- for another paying phone (sim rule 16): relay_lapsed_at is set while it is
-- lapsed (cleared when a fresh account read shows it paying again). A relay
-- action of that phone sent before its lapse — one it was told is not
-- delivered — is never applied later: an ordered one by its action_seq
-- (relay_skip_seq, the highest the hub saw), a legacy one by time
-- (relay_skip_before). Times and a counter only.
ALTER TABLE devices ADD COLUMN relay_lapsed_at REAL;
ALTER TABLE devices ADD COLUMN relay_skip_before REAL;
ALTER TABLE devices ADD COLUMN relay_skip_seq INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE devices DROP COLUMN relay_skip_seq;
ALTER TABLE devices DROP COLUMN relay_skip_before;
ALTER TABLE devices DROP COLUMN relay_lapsed_at;
ALTER TABLE hub_epochs DROP COLUMN retire_after;
ALTER TABLE hub_epochs DROP COLUMN reason;
