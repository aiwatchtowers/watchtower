-- +goose Up
-- The Go hub's own state. New columns hold no content (spec §8 p. 4a): ids,
-- counters, timestamps and error classes only; envelopes are sealed.

-- Ordered actions per phone: the last applied action_seq, whether the phone
-- sends action_seq, its relay device id, and the gap a resend_from was
-- already written for (one per gap).
ALTER TABLE devices ADD COLUMN last_applied_action_seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN ordered INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN relay_device_id TEXT;
ALTER TABLE devices ADD COLUMN resend_requested_from INTEGER NOT NULL DEFAULT 0;

-- Echoes and controls waiting to be written to a phone's mailbox, in id
-- order, retried every pass. record_name is the opaque wire name, envelope a
-- sealed envelope, last_error_class an error class, never error text.
CREATE TABLE control_queue (
    id INTEGER PRIMARY KEY,
    mailbox TEXT NOT NULL,
    record_name TEXT NOT NULL,
    kind TEXT NOT NULL,
    envelope BLOB NOT NULL,
    expect TEXT NOT NULL CHECK (expect IN ('none', 'absent', 'seq')),
    expect_seq INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error_class TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX control_queue_by_mailbox ON control_queue (mailbox, id);

-- Actions that arrived ahead of a gap: wire name and sealed envelope.
CREATE TABLE held_actions (
    device_id TEXT NOT NULL,
    action_seq INTEGER NOT NULL,
    record_name TEXT NOT NULL,
    envelope BLOB NOT NULL,
    held_at REAL NOT NULL,
    PRIMARY KEY (device_id, action_seq)
);

-- The transport's change token per zone (the hosted relay's since_seq).
CREATE TABLE zone_tokens (
    zone TEXT PRIMARY KEY,
    since_seq INTEGER NOT NULL
);

-- +goose Down
DROP TABLE zone_tokens;
DROP TABLE held_actions;
DROP TABLE control_queue;
ALTER TABLE devices DROP COLUMN resend_requested_from;
ALTER TABLE devices DROP COLUMN relay_device_id;
ALTER TABLE devices DROP COLUMN ordered;
ALTER TABLE devices DROP COLUMN last_applied_action_seq;
