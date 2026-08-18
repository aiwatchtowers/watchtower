-- +goose Up
-- Slack digests have no advancing watermark of their own — lastDigestTime()
-- derives the next window's start from MAX(digests.period_to). Persist a
-- fast-forward floor so re-enabling the slack-digests feature (FEAT-03) resumes
-- from "now" instead of re-digesting the backlog that accrued while it was off.
ALTER TABLE workspace ADD COLUMN digest_fastforward_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE workspace DROP COLUMN digest_fastforward_ts;
