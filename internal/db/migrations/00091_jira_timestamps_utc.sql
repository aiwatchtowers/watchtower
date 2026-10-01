-- +goose Up
-- Data-only rewrite of the Jira timestamp columns to RFC3339 UTC in whole
-- seconds (db.FormatJiraTime), the form the sync and the tools mirror now
-- write. Jira returns "2026-01-02T15:04:05.000+0300" in the Jira profile's
-- own offset: SQLite's julianday() rejects the colon-less offset (dashboard
-- cycle times came out NULL) and a string compare orders such values by wall
-- time, so a DST or profile time-zone change misordered them against the
-- ideas floor and every RFC3339 UTC bound. Copies of these values are
-- rewritten too, so they keep matching their source rows: the ideas Jira
-- floor, the jira inbox items' message_ts (the detector's dedupe key) and
-- the Jira stream digests' periods.
--
-- Only a full timestamp carrying a zone ("Z", "+hhmm" or "+hh:mm", any
-- fraction) that is not already canonical is touched; strftime() returns NULL
-- for anything it cannot read and such a value is kept verbatim, so no value
-- is lost and a re-run changes nothing. UPDATE OR IGNORE leaves an inbox item
-- or digest alone if its rewritten value would collide with a sibling row's
-- unique key.

UPDATE jira_issues SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(created_at, 1, length(created_at) - 2) || ':' || substr(created_at, -2) ELSE created_at END)
WHERE created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND created_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (created_at GLOB '*Z' OR created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR created_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(created_at, 1, length(created_at) - 2) || ':' || substr(created_at, -2) ELSE created_at END) IS NOT NULL;

UPDATE jira_issues SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(updated_at, 1, length(updated_at) - 2) || ':' || substr(updated_at, -2) ELSE updated_at END)
WHERE updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND updated_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (updated_at GLOB '*Z' OR updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR updated_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(updated_at, 1, length(updated_at) - 2) || ':' || substr(updated_at, -2) ELSE updated_at END) IS NOT NULL;

UPDATE jira_issues SET resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN resolved_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(resolved_at, 1, length(resolved_at) - 2) || ':' || substr(resolved_at, -2) ELSE resolved_at END)
WHERE resolved_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND resolved_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (resolved_at GLOB '*Z' OR resolved_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR resolved_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN resolved_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(resolved_at, 1, length(resolved_at) - 2) || ':' || substr(resolved_at, -2) ELSE resolved_at END) IS NOT NULL;

UPDATE jira_issues SET status_category_changed_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN status_category_changed_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(status_category_changed_at, 1, length(status_category_changed_at) - 2) || ':' || substr(status_category_changed_at, -2) ELSE status_category_changed_at END)
WHERE status_category_changed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND status_category_changed_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (status_category_changed_at GLOB '*Z' OR status_category_changed_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR status_category_changed_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN status_category_changed_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(status_category_changed_at, 1, length(status_category_changed_at) - 2) || ':' || substr(status_category_changed_at, -2) ELSE status_category_changed_at END) IS NOT NULL;

UPDATE jira_comments SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(created_at, 1, length(created_at) - 2) || ':' || substr(created_at, -2) ELSE created_at END)
WHERE created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND created_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (created_at GLOB '*Z' OR created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR created_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN created_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(created_at, 1, length(created_at) - 2) || ':' || substr(created_at, -2) ELSE created_at END) IS NOT NULL;

UPDATE jira_comments SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(updated_at, 1, length(updated_at) - 2) || ':' || substr(updated_at, -2) ELSE updated_at END)
WHERE updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND updated_at NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (updated_at GLOB '*Z' OR updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' OR updated_at GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN updated_at GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(updated_at, 1, length(updated_at) - 2) || ':' || substr(updated_at, -2) ELSE updated_at END) IS NOT NULL;

UPDATE jira_accounts SET ideas_jira_floor = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN ideas_jira_floor GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(ideas_jira_floor, 1, length(ideas_jira_floor) - 2) || ':' || substr(ideas_jira_floor, -2) ELSE ideas_jira_floor END)
WHERE ideas_jira_floor GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND ideas_jira_floor NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (ideas_jira_floor GLOB '*Z' OR ideas_jira_floor GLOB '*[+-][0-9][0-9][0-9][0-9]' OR ideas_jira_floor GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN ideas_jira_floor GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(ideas_jira_floor, 1, length(ideas_jira_floor) - 2) || ':' || substr(ideas_jira_floor, -2) ELSE ideas_jira_floor END) IS NOT NULL;

UPDATE OR IGNORE inbox_items SET message_ts = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN message_ts GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(message_ts, 1, length(message_ts) - 2) || ':' || substr(message_ts, -2) ELSE message_ts END)
WHERE message_ts GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND message_ts NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (message_ts GLOB '*Z' OR message_ts GLOB '*[+-][0-9][0-9][0-9][0-9]' OR message_ts GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN message_ts GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(message_ts, 1, length(message_ts) - 2) || ':' || substr(message_ts, -2) ELSE message_ts END) IS NOT NULL AND trigger_type IN ('jira_assigned', 'jira_comment_mention');

UPDATE OR IGNORE stream_digests SET period_from = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN period_from GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(period_from, 1, length(period_from) - 2) || ':' || substr(period_from, -2) ELSE period_from END)
WHERE period_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND period_from NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (period_from GLOB '*Z' OR period_from GLOB '*[+-][0-9][0-9][0-9][0-9]' OR period_from GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN period_from GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(period_from, 1, length(period_from) - 2) || ':' || substr(period_from, -2) ELSE period_from END) IS NOT NULL AND source = 'jira';

UPDATE OR IGNORE stream_digests SET period_to = strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN period_to GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(period_to, 1, length(period_to) - 2) || ':' || substr(period_to, -2) ELSE period_to END)
WHERE period_to GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]?*'
  AND period_to NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
  AND (period_to GLOB '*Z' OR period_to GLOB '*[+-][0-9][0-9][0-9][0-9]' OR period_to GLOB '*[+-][0-9][0-9]:[0-9][0-9]')
  AND strftime('%Y-%m-%dT%H:%M:%SZ', CASE WHEN period_to GLOB '*[+-][0-9][0-9][0-9][0-9]' THEN substr(period_to, 1, length(period_to) - 2) || ':' || substr(period_to, -2) ELSE period_to END) IS NOT NULL AND source = 'jira';

-- +goose Down
-- Nothing to undo: the rewritten values are the same instants, and every
-- reader parses both forms.
SELECT 1;
