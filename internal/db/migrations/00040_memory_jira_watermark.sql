-- +goose Up
-- Secretary memory Jira source (docs/superpowers/specs/2026-07-22-memory-jira-source-design.md):
-- the FIFTH extraction watermark — parsed jira_issues.updated_at (unix seconds)
-- the mechanical issue→episode builder has fully committed through. Distinct
-- from the Slack (memory_last_extracted_ts), Gmail
-- (memory_gmail_last_extracted_ts), calendar (memory_calendar_last_extracted_ts)
-- watermarks and the interaction floor. Additive, no CHECK change — the
-- 00033/00037 ALTER TABLE precedent.
ALTER TABLE workspace ADD COLUMN memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE workspace DROP COLUMN memory_jira_last_extracted_ts;
