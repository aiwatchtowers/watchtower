-- +goose Up
-- Watchman phase 2 (Task 17, fix round 1), both written by the Desktop only:
-- owner_done_at — the owner marked a parked, handed or guard item done, so it
-- leaves Waiting for you (feedback is untouched: it is not a decision);
-- correction_sent_at — his correction reached a session (typed into it, or a
-- new session started with it), so an unsent one survives a relaunch.
ALTER TABLE watchman_items ADD COLUMN owner_done_at TEXT;
ALTER TABLE watchman_items ADD COLUMN correction_sent_at TEXT;
-- A correction stored before this column existed was delivered (or its
-- failure seen) by the build that wrote it: it is not Not sent.
UPDATE watchman_items SET correction_sent_at = COALESCE(feedback_at, created_at)
WHERE feedback = 'corrected' AND correction_sent_at IS NULL;

-- +goose Down
ALTER TABLE watchman_items DROP COLUMN correction_sent_at;
ALTER TABLE watchman_items DROP COLUMN owner_done_at;
