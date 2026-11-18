-- +goose NO TRANSACTION
-- +goose Up
-- Two more latency steps (live link spec R7) and the action kind:
-- event_read is a mailbox event's arrival → the mailbox read it starts;
-- nudge_saved is an applied action → the end of the first cycle that handled
-- a slice kind it nudged, written or not. kind is the action's kind name (a
-- fixed vocabulary such as board_target_create; '' for event_read and for the
-- rows before this migration): still no device, record or action id and no
-- content. SQLite cannot change a CHECK in place, so the table is rebuilt in
-- one transaction (one goose statement); it has no foreign keys either way.
PRAGMA foreign_keys = OFF;

-- +goose StatementBegin
BEGIN IMMEDIATE;
CREATE TABLE latency_samples_new (
    at REAL NOT NULL,
    transport TEXT NOT NULL CHECK (transport IN ('cloudkit', 'relay')),
    step TEXT NOT NULL CHECK (step IN ('read_applied', 'applied_saved', 'read_saved', 'event_read', 'nudge_saved')),
    ms INTEGER NOT NULL CHECK (ms >= 0),
    kind TEXT NOT NULL DEFAULT ''
);
INSERT INTO latency_samples_new (at, transport, step, ms) SELECT at, transport, step, ms FROM latency_samples;
DROP TABLE latency_samples;
ALTER TABLE latency_samples_new RENAME TO latency_samples;
CREATE INDEX IF NOT EXISTS latency_samples_at ON latency_samples(at);
COMMIT;
-- +goose StatementEnd

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;

-- +goose StatementBegin
BEGIN IMMEDIATE;
CREATE TABLE latency_samples_old (
    at REAL NOT NULL,
    transport TEXT NOT NULL CHECK (transport IN ('cloudkit', 'relay')),
    step TEXT NOT NULL CHECK (step IN ('read_applied', 'applied_saved', 'read_saved')),
    ms INTEGER NOT NULL CHECK (ms >= 0)
);
INSERT INTO latency_samples_old (at, transport, step, ms) SELECT at, transport, step, ms FROM latency_samples
    WHERE step IN ('read_applied', 'applied_saved', 'read_saved');
DROP TABLE latency_samples;
ALTER TABLE latency_samples_old RENAME TO latency_samples;
CREATE INDEX IF NOT EXISTS latency_samples_at ON latency_samples(at);
COMMIT;
-- +goose StatementEnd

PRAGMA foreign_keys = ON;
