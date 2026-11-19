-- +goose Up
-- Hub-side latency samples (Go hub plan 4 Task 6, RC §10): how long this Mac
-- took from reading a phone's action to applying it and to saving the slice
-- that shows the result. A time, two enums and a duration only: no device,
-- record or action id, no kind, no content. Kept 7 days and at most 20 000
-- rows (internal/hub/measure prunes once a minute); never sent anywhere.
CREATE TABLE latency_samples (
    at REAL NOT NULL,
    transport TEXT NOT NULL CHECK (transport IN ('cloudkit', 'relay')),
    step TEXT NOT NULL CHECK (step IN ('read_applied', 'applied_saved', 'read_saved')),
    ms INTEGER NOT NULL CHECK (ms >= 0)
);
CREATE INDEX latency_samples_at ON latency_samples(at);

-- +goose Down
DROP INDEX latency_samples_at;
DROP TABLE latency_samples;
