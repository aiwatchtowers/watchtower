-- +goose Up
-- Revoked access wipes the account's data (board #601,
-- docs/features/revoke-purge.md once written; spec
-- docs/superpowers/specs/2026-10-21-revoke-purge-design.md).
--
-- Two per-account facts on the four account tables:
--   access_ok_at  RFC 3339 UTC of the last authenticated call that succeeded
--                 ('' = unknown). Written by the auth-state writers on 'ok'
--                 and by db.MarkAccountAccessOK after a clean Jira/Linear pass;
--                 it never changes status.
--   revoked_at    RFC 3339 UTC when status turned 'revoked' (kept on a repeat,
--                 cleared by 'ok', kept by 'error').
-- status gains the value 'purged' (no CHECK on any of the four columns).
ALTER TABLE slack_accounts  ADD COLUMN access_ok_at TEXT NOT NULL DEFAULT '';
ALTER TABLE slack_accounts  ADD COLUMN revoked_at   TEXT NOT NULL DEFAULT '';
ALTER TABLE google_accounts ADD COLUMN access_ok_at TEXT NOT NULL DEFAULT '';
ALTER TABLE google_accounts ADD COLUMN revoked_at   TEXT NOT NULL DEFAULT '';
ALTER TABLE jira_accounts   ADD COLUMN access_ok_at TEXT NOT NULL DEFAULT '';
ALTER TABLE jira_accounts   ADD COLUMN revoked_at   TEXT NOT NULL DEFAULT '';
ALTER TABLE linear_accounts ADD COLUMN access_ok_at TEXT NOT NULL DEFAULT '';
ALTER TABLE linear_accounts ADD COLUMN revoked_at   TEXT NOT NULL DEFAULT '';

-- An upgrade starts every clock at the upgrade, never in the past. Removed
-- accounts too: they take part in the lease (ask #477).
UPDATE slack_accounts  SET access_ok_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
UPDATE google_accounts SET access_ok_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
UPDATE jira_accounts   SET access_ok_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
UPDATE linear_accounts SET access_ok_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
UPDATE slack_accounts  SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE status = 'revoked';
UPDATE google_accounts SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE status = 'revoked';
UPDATE jira_accounts   SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE status = 'revoked';
UPDATE linear_accounts SET revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE status = 'revoked';

-- The purge ledger: one row per scheduled purge. No foreign key — four
-- parent tables, and the account row is never deleted by a purge.
-- failures counts chunk failures since the last chunk that deleted rows; the
-- third ends the row in the terminal state 'failed'.
CREATE TABLE IF NOT EXISTS account_purges (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK (source IN ('slack','google','jira','linear')),
    account_id   INTEGER NOT NULL,
    reason       TEXT NOT NULL CHECK (reason IN ('revoked','lease')),
    scheduled_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    due_at       TEXT NOT NULL,
    state        TEXT NOT NULL DEFAULT 'scheduled'
                 CHECK (state IN ('scheduled','running','done','cancelled','failed')),
    started_at   TEXT NOT NULL DEFAULT '',
    finished_at  TEXT NOT NULL DEFAULT '',
    rows_deleted INTEGER NOT NULL DEFAULT 0,
    error        TEXT NOT NULL DEFAULT '',
    failures     INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_purges_open
    ON account_purges(source, account_id) WHERE state IN ('scheduled','running');

-- +goose Down
DROP INDEX IF EXISTS idx_account_purges_open;
DROP TABLE IF EXISTS account_purges;
ALTER TABLE linear_accounts DROP COLUMN revoked_at;
ALTER TABLE linear_accounts DROP COLUMN access_ok_at;
ALTER TABLE jira_accounts   DROP COLUMN revoked_at;
ALTER TABLE jira_accounts   DROP COLUMN access_ok_at;
ALTER TABLE google_accounts DROP COLUMN revoked_at;
ALTER TABLE google_accounts DROP COLUMN access_ok_at;
ALTER TABLE slack_accounts  DROP COLUMN revoked_at;
ALTER TABLE slack_accounts  DROP COLUMN access_ok_at;
