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
		SELECT id, name, domain, synced_at, current_user_id FROM workspace LIMIT 1`,
	).Scan(&ws.ID, &ws.Name, &ws.Domain, &ws.SyncedAt, &ws.CurrentUserID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("getting workspace: %w", err)
	}
	return &ws, nil
}

// GetSearchLastDate returns the search_last_date for the workspace, or "" if not set.
func (db *DB) GetSearchLastDate() (string, error) {
	var date string
	err := db.QueryRow(`SELECT search_last_date FROM workspace LIMIT 1`).Scan(&date)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting search_last_date: %w", err)
	}
	return date, nil
}

// SetCurrentUserID updates the current_user_id for the workspace.
func (db *DB) SetCurrentUserID(userID string) error {
	res, err := db.Exec(`UPDATE workspace SET current_user_id = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, userID)
	if err != nil {
		return fmt.Errorf("setting current_user_id: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("setting current_user_id: no workspace row exists")
	}
	return nil
}

// GetCurrentUserID returns the current_user_id for the workspace.
func (db *DB) GetCurrentUserID() (string, error) {
	var userID string
	err := db.QueryRow(`SELECT current_user_id FROM workspace LIMIT 1`).Scan(&userID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting current_user_id: %w", err)
	}
	return userID, nil
}

// TouchSyncedAt updates the workspace synced_at timestamp to now.
func (db *DB) TouchSyncedAt() error {
	_, err := db.Exec(`UPDATE workspace SET synced_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`)
	return err
}

// SetSearchLastDate updates the search_last_date for the workspace.
func (db *DB) SetSearchLastDate(date string) error {
	res, err := db.Exec(`UPDATE workspace SET search_last_date = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, date)
	if err != nil {
		return fmt.Errorf("setting search_last_date: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("setting search_last_date: no workspace row exists")
	}
	return nil
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
