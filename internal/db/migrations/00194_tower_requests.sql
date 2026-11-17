-- +goose Up
-- The tower request ledger (#1170): exactly-once writes for the commands that
-- reach internal/tower over the daemon socket and through the hub. Go-written
-- by internal/tower only; the daemon prunes rows past the hub ledger window.
--   request_id   the client's UUID, kept across its retries of one press
--   command      the tower command name (domain.verb)
--   state        begun = a non-idempotent command committed its intent and
--                acts outside the transaction; done = the write committed
--   result_json  the command's marshalled response ('' while begun or
--                when it refused)
--   refusal_json a non-idempotent command's marshalled refusal on a done
--                row ('' otherwise); a resend answers the same refusal
--   at           when the row was last written (UTC, %Y-%m-%dT%H:%M:%SZ)
CREATE TABLE tower_requests (
    request_id  TEXT PRIMARY KEY,
    command     TEXT NOT NULL,
    state       TEXT NOT NULL CHECK (state IN ('begun','done')),
    result_json TEXT NOT NULL DEFAULT '',
    refusal_json TEXT NOT NULL DEFAULT '',
    at          TEXT NOT NULL
);
CREATE INDEX idx_tower_requests_at ON tower_requests(at);

-- +goose Down
DROP INDEX IF EXISTS idx_tower_requests_at;
DROP TABLE IF EXISTS tower_requests;
