-- +goose Up
-- Why each epoch began, and until when a retired epoch's relay-lane keys are
-- accepted (Go hub plan 3 Task 20, relay sim rule 14 with the 7-day cap of
-- ask #843): an enum and a time only, no content. A row written before this
-- migration has neither; its retention is read from retired_at.
ALTER TABLE hub_epochs ADD COLUMN reason TEXT CHECK (reason IN ('age', 'cap', 'unlink', 'manual', 'transport_switch'));
ALTER TABLE hub_epochs ADD COLUMN retire_after REAL;
-- A phone whose relay entitlement lapsed while the hub stays on the relay
-- for another paying phone (sim rule 16): relay_lapsed_at is set while it is
-- lapsed (cleared when a fresh account read shows it paying again);
-- relay_skip_before stays, so a relay action of that phone written before
-- its lapse — one it was told is not delivered — is never applied later.
-- Times only.
ALTER TABLE devices ADD COLUMN relay_lapsed_at REAL;
ALTER TABLE devices ADD COLUMN relay_skip_before REAL;

-- +goose Down
ALTER TABLE devices DROP COLUMN relay_skip_before;
ALTER TABLE devices DROP COLUMN relay_lapsed_at;
ALTER TABLE hub_epochs DROP COLUMN retire_after;
ALTER TABLE hub_epochs DROP COLUMN reason;
