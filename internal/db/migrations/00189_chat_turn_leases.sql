-- +goose Up
-- iPhone chat (#1791 T1): one row per conversation whose turn is running, so
-- only one process (the Desktop app or the Go hub) runs a turn at a time.
-- Every time is Unix epoch milliseconds (UTC), compared as a number.
CREATE TABLE chat_turn_leases (
  conversation_id        INTEGER PRIMARY KEY REFERENCES chat_conversations(id) ON DELETE CASCADE,
  owner                  TEXT NOT NULL CHECK (owner IN ('desktop','hub')),
  owner_id               TEXT NOT NULL,
  turn_id                TEXT NOT NULL,
  started_at_ms          INTEGER NOT NULL,
  heartbeat_at_ms        INTEGER NOT NULL,
  cancel_requested_at_ms INTEGER
);

-- +goose Down
DROP TABLE chat_turn_leases;
