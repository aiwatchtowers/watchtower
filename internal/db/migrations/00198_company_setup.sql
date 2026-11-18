-- +goose Up
-- Company setup (#1887, docs/superpowers/specs/2026-11-17-company-setup-design.md
-- §1, §4b, §6). company_slug ties an account to the company bundle whose
-- OAuth client it signed in with (<workspace>/company/<slug>.json); '' = our
-- shared client (or, for Google, an own per-account credentials file).
ALTER TABLE slack_accounts  ADD COLUMN company_slug TEXT NOT NULL DEFAULT '';
ALTER TABLE google_accounts ADD COLUMN company_slug TEXT NOT NULL DEFAULT '';
ALTER TABLE jira_accounts   ADD COLUMN company_slug TEXT NOT NULL DEFAULT '';
ALTER TABLE linear_accounts ADD COLUMN company_slug TEXT NOT NULL DEFAULT '';
ALTER TABLE email_accounts  ADD COLUMN company_slug TEXT NOT NULL DEFAULT '';
-- How a Jira account signs in: an OAuth token or an Atlassian API token (§4b).
ALTER TABLE jira_accounts ADD COLUMN auth_kind TEXT NOT NULL DEFAULT 'oauth' CHECK (auth_kind IN ('oauth','api_token'));
-- RFC 3339 UTC of the last whole-account Personal Data Reporting pass (§6); '' = never.
ALTER TABLE jira_accounts ADD COLUMN last_pdr_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE jira_accounts DROP COLUMN last_pdr_at;
ALTER TABLE jira_accounts DROP COLUMN auth_kind;
ALTER TABLE email_accounts  DROP COLUMN company_slug;
ALTER TABLE linear_accounts DROP COLUMN company_slug;
ALTER TABLE jira_accounts   DROP COLUMN company_slug;
ALTER TABLE google_accounts DROP COLUMN company_slug;
ALTER TABLE slack_accounts  DROP COLUMN company_slug;
