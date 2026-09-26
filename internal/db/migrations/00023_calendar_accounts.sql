-- +goose Up
-- Multi-account open-protocol calendar sources: one row per connected CalDAV
-- server (username/password basic auth) or secret ICS feed URL. The exact
-- calendar analog of 00022's email_accounts. Purely additive — the existing
-- Google Calendar singleton flow (calendar_auth_state, calendar_calendars,
-- calendar_events) is untouched; each account's events land in the shared
-- calendar_events table scoped by calendar_id = 'caldav:<id>' / 'ics:<id>'.
-- For provider='ics' the url column stays EMPTY: the secret feed URL is
-- itself a credential and lives in the per-account credential file, never
-- the DB.

CREATE TABLE IF NOT EXISTS calendar_accounts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    provider   TEXT NOT NULL CHECK(provider IN ('caldav','ics')),
    username   TEXT NOT NULL DEFAULT '',
    url        TEXT NOT NULL DEFAULT '',      -- CalDAV server base URL ONLY; empty for provider='ics'
    label      TEXT NOT NULL DEFAULT '',      -- user-facing display name
    status     TEXT NOT NULL DEFAULT 'ok',    -- ok | error | revoked
    error      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- +goose Down
DROP TABLE IF EXISTS calendar_accounts;
