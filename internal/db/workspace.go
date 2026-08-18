package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// UpsertWorkspace inserts or updates a workspace.
func (db *DB) UpsertWorkspace(ws Workspace) error {
	_, err := db.Exec(`
		INSERT INTO workspace (id, name, domain, synced_at)
		VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(id) DO UPDATE SET
			name = excluded.name,
			domain = excluded.domain,
			synced_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		ws.ID, ws.Name, ws.Domain,
	)
	if err != nil {
		return fmt.Errorf("upserting workspace %s: %w", ws.ID, err)
	}
	return nil
}

// GetWorkspace returns the first workspace found, or nil if none exist.
func (db *DB) GetWorkspace() (*Workspace, error) {
	var ws Workspace
	err := db.QueryRow(`
		SELECT id, name, domain, synced_at FROM workspace LIMIT 1`,
	).Scan(&ws.ID, &ws.Name, &ws.Domain, &ws.SyncedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("getting workspace: %w", err)
	}
	return &ws, nil
}

// GetCurrentUserID returns account #1's Slack user id — the app's canonical
// owner identity for Jira/style-sample/people-card purposes. Pinned to
// account #1 in v1; does not widen across additional connected accounts.
func (db *DB) GetCurrentUserID() (string, error) {
	var userID string
	err := db.QueryRow(`SELECT current_user_id FROM slack_accounts WHERE id = 1`).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting current_user_id: %w", err)
	}
	return userID, nil
}

// TouchSyncedAt updates the workspace synced_at timestamp to now.
func (db *DB) TouchSyncedAt() error {
	_, err := db.Exec(`UPDATE workspace SET synced_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`)
	return err
}

// GetComposeLastRunTS returns the last processed timestamp for the situation composer.
func (db *DB) GetComposeLastRunTS() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(compose_last_run_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if err != nil {
		return 0, fmt.Errorf("getting compose last run ts: %w", err)
	}
	return ts, nil
}

// SetComposeLastRunTS updates the last processed timestamp for the situation composer.
func (db *DB) SetComposeLastRunTS(ts float64) error {
	return setComposeLastRunTSOn(db, ts)
}

// SetComposeLastRunTSTx is the transactional variant of SetComposeLastRunTS,
// for callers (the compose apply loop) that need the watermark advance to
// commit atomically with the rest of that pass's mutations (DASH-02).
func (db *DB) SetComposeLastRunTSTx(tx *sql.Tx, ts float64) error {
	return setComposeLastRunTSOn(tx, ts)
}

func setComposeLastRunTSOn(q situationsExecer, ts float64) error {
	_, err := q.Exec(`UPDATE workspace SET compose_last_run_ts = ?`, ts)
	if err != nil {
		return fmt.Errorf("setting compose last run ts: %w", err)
	}
	return nil
}

// GetDigestFastForwardTS returns the persisted Slack-digest fast-forward floor.
// Slack digests have no advancing watermark of their own — the pipeline derives
// the next window from MAX(digests.period_to) — so this floor is what lets a
// slack-digests re-enable (FEAT-03) resume from "now" instead of re-digesting
// the backlog. lastDigestTime returns max(derived, this). 0 = never set.
func (db *DB) GetDigestFastForwardTS() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(digest_fastforward_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting digest fast-forward ts: %w", err)
	}
	return ts, nil
}

// SetDigestFastForwardTS stamps the Slack-digest fast-forward floor.
func (db *DB) SetDigestFastForwardTS(ts float64) error {
	_, err := db.Exec(`UPDATE workspace SET digest_fastforward_ts = ?`, ts)
	if err != nil {
		return fmt.Errorf("setting digest fast-forward ts: %w", err)
	}
	return nil
}

// GetSecretaryProfile returns the user-written secretary brief text.
func (db *DB) GetSecretaryProfile() (string, error) {
	var s string
	err := db.QueryRow(`SELECT secretary_profile FROM workspace LIMIT 1`).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return s, err
}

// SetSecretaryProfile stores the user-written secretary brief text.
func (db *DB) SetSecretaryProfile(text string) error {
	res, err := db.Exec(`UPDATE workspace SET secretary_profile = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, text)
	if err != nil {
		return fmt.Errorf("setting secretary_profile: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting secretary_profile: no workspace row exists")
	}
	return nil
}

// GetStyleProfile returns the stored communication style profile text.
func (db *DB) GetStyleProfile() (string, error) {
	var s string
	err := db.QueryRow(`SELECT style_profile FROM workspace LIMIT 1`).Scan(&s)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting style_profile: %w", err)
	}
	return s, nil
}

// SetStyleProfile stores the communication style profile and stamps its
// generation/edit time.
func (db *DB) SetStyleProfile(text string) error {
	res, err := db.Exec(`UPDATE workspace SET style_profile = ?,
		style_profile_updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = (SELECT id FROM workspace LIMIT 1)`, text)
	if err != nil {
		return fmt.Errorf("setting style_profile: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting style_profile: no workspace row exists")
	}
	return nil
}
