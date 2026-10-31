-- +goose Up
-- The Swift hub's hubstate.db as HubSyncState.createSchema, createLinkTables,
-- createKeyTables and createSliceAssetTable leave it today, with the columns
-- they add by ALTER TABLE folded into each CREATE. Every statement is
-- IF NOT EXISTS so the same file applies to an adopted Swift sidecar
-- (phase 3), which already holds these tables. Device ids are compared
-- COLLATE NOCASE by the queries, as the Swift hub does.

CREATE TABLE IF NOT EXISTS slice_state (
    record_name TEXT PRIMARY KEY,
    payload_hash TEXT NOT NULL,
    pushed_at REAL NOT NULL DEFAULT 0,
    wire_name TEXT
);

CREATE TABLE IF NOT EXISTS hub_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS work_alerts (
    key TEXT PRIMARY KEY,
    seen_at REAL NOT NULL,
    pushed_at REAL,
    generation INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS relay_processed (
    record_name TEXT PRIMARY KEY,
    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
    outcome TEXT,
    updated_at REAL NOT NULL DEFAULT 0,
    echo BLOB,
    done_seq INTEGER
);

CREATE TABLE IF NOT EXISTS ask_answer_deliveries (
    record_name TEXT PRIMARY KEY,
    delivery TEXT NOT NULL,
    at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS phone_recordings (
    upload_id TEXT PRIMARY KEY,
    audio_path TEXT NOT NULL,
    transcript_id INTEGER,
    status TEXT NOT NULL,
    percent INTEGER,
    error TEXT,
    updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS session_reports (
    session_id INTEGER PRIMARY KEY,
    payload BLOB NOT NULL,
    fetched_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS session_milestones (
    session_id INTEGER NOT NULL,
    at REAL NOT NULL,
    kind TEXT NOT NULL CHECK (kind = 'state'),
    text TEXT NOT NULL,
    ref INTEGER
);
CREATE INDEX IF NOT EXISTS session_milestones_by_session ON session_milestones (session_id, at);

CREATE TABLE IF NOT EXISTS held_session_lines (
    record_name TEXT PRIMARY KEY,
    action BLOB NOT NULL,
    session_id INTEGER NOT NULL,
    line TEXT NOT NULL,
    run INTEGER,
    launch TEXT NOT NULL,
    reason TEXT NOT NULL,
    typing INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS link_codes (
    nonce TEXT PRIMARY KEY,
    issued_at REAL NOT NULL,
    exp REAL NOT NULL,
    used_by_device TEXT,
    used_at REAL,
    confirm_nonces_drawn INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    user_record_name TEXT NOT NULL,
    linked_at REAL NOT NULL,
    typing_allowed INTEGER NOT NULL DEFAULT 0,
    -- The phone's own toggle (its opt-out); start_sessions_granted is the owner's grant.
    start_sessions_allowed INTEGER NOT NULL DEFAULT 1,
    decided_at REAL,
    typing_requested INTEGER NOT NULL DEFAULT 0,
    permissions_allowed INTEGER NOT NULL DEFAULT 0,
    permissions_requested INTEGER NOT NULL DEFAULT 0,
    start_sessions_granted INTEGER NOT NULL DEFAULT 0,
    signing_key BLOB,
    agreement_key BLOB,
    link_nonce TEXT,
    last_seq INTEGER
);

CREATE TABLE IF NOT EXISTS link_refusals (
    device_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    reason TEXT NOT NULL,
    at REAL NOT NULL,
    agreement_key BLOB
);

CREATE TABLE IF NOT EXISTS hub_epochs (
    epoch INTEGER PRIMARY KEY,
    sealed_keys BLOB NOT NULL,
    created_at REAL NOT NULL,
    first_seq INTEGER NOT NULL,
    retired_at REAL
);

CREATE TABLE IF NOT EXISTS pending_devices (
    device_id TEXT PRIMARY KEY,
    name TEXT,
    model TEXT,
    scope TEXT,
    user_record_name TEXT,
    signing_key BLOB,
    agreement_key BLOB,
    link_nonce TEXT,
    sas TEXT,
    received_at REAL,
    typing_requested INTEGER NOT NULL DEFAULT 0,
    confirm_nonce BLOB,
    start_sessions INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS revoked_devices (
    device_id TEXT PRIMARY KEY,
    agreement_key BLOB NOT NULL,
    removed_at REAL NOT NULL,
    name TEXT,
    scope TEXT
);

CREATE TABLE IF NOT EXISTS relay_seen (
    wire_name TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    epoch INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    at REAL NOT NULL,
    PRIMARY KEY (wire_name, sender_id)
);

CREATE TABLE IF NOT EXISTS slice_assets (
    file_path TEXT PRIMARY KEY,
    descriptor BLOB NOT NULL
);

CREATE INDEX IF NOT EXISTS slice_state_by_wire ON slice_state (wire_name);

-- +goose Down
-- Drops nothing: the baseline may describe an adopted Swift sidecar whose
-- tables predate this migration, and rolling back must never destroy the
-- links, keys and ledger they hold.
SELECT 1;
