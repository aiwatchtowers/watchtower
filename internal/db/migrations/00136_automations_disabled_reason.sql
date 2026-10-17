-- +goose Up
-- Why the daemon turned an automation off by itself (a runaway script, #584),
-- and when; '' / NULL when the owner set enabled. Any enable or disable by
-- the owner clears both.
ALTER TABLE automations ADD COLUMN disabled_reason TEXT NOT NULL DEFAULT '';
ALTER TABLE automations ADD COLUMN disabled_at TEXT;

-- +goose Down
ALTER TABLE automations DROP COLUMN disabled_at;
ALTER TABLE automations DROP COLUMN disabled_reason;
