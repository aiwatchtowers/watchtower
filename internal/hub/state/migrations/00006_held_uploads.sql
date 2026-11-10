-- +goose Up
-- Held phone recording uploads (Go hub plan 2 Task 9, protocol §7.7, §9): an
-- upload answered held while Desktop, the transcriber, is away. held_at is
-- the first hold (a resave of the same upload keeps it), so the 7-day expiry
-- and the switch-off failure survive a hub restart. Ids, timestamps and an
-- outcome class only: no record name, no title, no text.
CREATE TABLE held_uploads (
    upload_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    held_at REAL NOT NULL,
    outcome TEXT CHECK (outcome IN ('received', 'not_supported', 'expired', 'failed')),
    settled_at REAL
);

-- +goose Down
DROP TABLE held_uploads;
