-- +goose Up
-- Why each epoch began, and until when a retired epoch's relay-lane keys are
-- accepted (Go hub plan 3 Task 20, relay sim rule 14 with the 7-day cap of
-- ask #843): an enum and a time only, no content. A row written before this
-- migration has neither; its retention is read from retired_at.
ALTER TABLE hub_epochs ADD COLUMN reason TEXT CHECK (reason IN ('age', 'cap', 'unlink', 'manual', 'transport_switch'));
ALTER TABLE hub_epochs ADD COLUMN retire_after REAL;

-- +goose Down
ALTER TABLE hub_epochs DROP COLUMN retire_after;
ALTER TABLE hub_epochs DROP COLUMN reason;
