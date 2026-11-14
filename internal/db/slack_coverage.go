package db

import (
	"database/sql"
	"fmt"
	"time"
)

// SlackCoverage is what the local Slack copy covers: whether the owner's
// own account is connected, how fresh the sync is, and how far back the
// history backfill reached. Live Slack fills the rest (#1764).
type SlackCoverage struct {
	Own           bool      // an enabled account with status ok exists
	SyncedThrough time.Time // newest successful channel sync; zero = none
	BackfillFrom  time.Time // earliest day every backfilled account reached; zero = unknown
}

// SlackCoverage reads the coverage from slack_accounts, sync_state and the
// Slack rows of history_backfill (the latest reached day: the safe edge).
func (db *DB) SlackCoverage() (SlackCoverage, error) {
	var c SlackCoverage
	accts, err := db.ListEnabledSlackAccounts()
	if err != nil {
		return c, err
	}
	for _, a := range accts {
		if a.Status == "ok" {
			c.Own = true
		}
	}
	var last sql.NullString
	if err := db.QueryRow(`SELECT MAX(last_sync_at) FROM sync_state WHERE last_sync_at IS NOT NULL AND last_sync_at != ''`).Scan(&last); err != nil {
		return c, fmt.Errorf("slack coverage sync: %w", err)
	}
	if last.Valid {
		if t, err := time.Parse(time.RFC3339, last.String); err == nil {
			c.SyncedThrough = t.UTC()
		}
	}
	var reached sql.NullFloat64
	if err := db.QueryRow(`SELECT MAX(reached_ts) FROM history_backfill WHERE source_kind = 'slack' AND status != 'off'`).Scan(&reached); err != nil {
		return c, fmt.Errorf("slack coverage backfill: %w", err)
	}
	if reached.Valid && reached.Float64 > 0 {
		c.BackfillFrom = time.Unix(int64(reached.Float64), 0).UTC()
	}
	return c, nil
}
