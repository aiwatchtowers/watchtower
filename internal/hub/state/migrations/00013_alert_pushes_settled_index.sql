-- +goose Up
-- The status reads the alert-push ledger by settled_at on every refresh
-- (the push-off line, the last outcome per phone, the overflow count): an
-- index keeps those reads off a full scan (Go hub plan 4 Task 7).
CREATE INDEX alert_pushes_settled_at ON alert_pushes (settled_at);

-- +goose Down
DROP INDEX alert_pushes_settled_at;
