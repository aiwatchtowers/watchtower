-- +goose Up
-- The hosted-relay device id a phone names in its hello (Go hub plan 1a
-- Task 12): kept with the waiting request and copied to devices.relay_device_id
-- at the link, so set_hub_readers can name the phone. An id, no content.
ALTER TABLE pending_devices ADD COLUMN relay_device_id TEXT;

-- +goose Down
ALTER TABLE pending_devices DROP COLUMN relay_device_id;
