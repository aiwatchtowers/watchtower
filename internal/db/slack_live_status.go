package db

import (
	"fmt"
	"time"
)

// SlackLiveStatus is one row of slack_live_status: the Slack Live probe's
// verdict for a workspace and provider.
type SlackLiveStatus struct {
	TeamID      string // '' = workspace not identified
	Provider    string // claude | codex
	Status      string // ok | not_connected | needs_admin | no_plan | unavailable
	ErrorClass  string
	ConnectorID string // the Codex Slack app id the probe saw; '' for Claude
	CheckedAt   time.Time
}

const slackLiveTimeLayout = "2006-01-02T15:04:05.000000000Z"

// UpsertSlackLiveStatus keeps the row with the newest CheckedAt per
// (team_id, provider); an older or equal write is a no-op. An empty
// ConnectorID never erases a known one.
func (db *DB) UpsertSlackLiveStatus(s SlackLiveStatus) error {
	_, err := db.Exec(`INSERT INTO slack_live_status (team_id, provider, status, error_class, connector_id, checked_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(team_id, provider) DO UPDATE SET
  status = excluded.status,
  error_class = excluded.error_class,
  checked_at = excluded.checked_at,
  connector_id = COALESCE(NULLIF(excluded.connector_id, ''), slack_live_status.connector_id)
WHERE excluded.checked_at > slack_live_status.checked_at`,
		s.TeamID, s.Provider, s.Status, s.ErrorClass, s.ConnectorID, s.CheckedAt.UTC().Format(slackLiveTimeLayout))
	if err != nil {
		return fmt.Errorf("upsert slack live status: %w", err)
	}
	return nil
}

// ListSlackLiveStatus returns every row, newest check first, so a caller can
// take the first row per provider.
func (db *DB) ListSlackLiveStatus() ([]SlackLiveStatus, error) {
	rows, err := db.Query(`SELECT team_id, provider, status, error_class, connector_id, checked_at
FROM slack_live_status ORDER BY checked_at DESC, team_id, provider`)
	if err != nil {
		return nil, fmt.Errorf("list slack live status: %w", err)
	}
	defer rows.Close()
	var out []SlackLiveStatus
	for rows.Next() {
		var s SlackLiveStatus
		var at string
		if err := rows.Scan(&s.TeamID, &s.Provider, &s.Status, &s.ErrorClass, &s.ConnectorID, &at); err != nil {
			return nil, fmt.Errorf("scan slack live status: %w", err)
		}
		t, err := time.Parse(slackLiveTimeLayout, at)
		if err != nil {
			return nil, fmt.Errorf("parse slack live checked_at %q: %w", at, err)
		}
		s.CheckedAt = t
		out = append(out, s)
	}
	return out, rows.Err()
}
