package state

import (
	"database/sql"
	"fmt"
	"time"
)

// Milestone is one session_milestones row (kind 'state'). Text is the
// stored value as is: the Go hub writes it sealed (identity.Keyring
// SealLocal, label "session_milestones.text"); an adopted Swift sidecar may
// hold plaintext rows, which the caller deletes.
type Milestone struct {
	RowID     int64
	SessionID int64
	At        time.Time
	Text      []byte
}

// Milestones returns every state milestone, by session and newest first
// (at, then rowid, descending).
func Milestones(tx *sql.Tx) ([]Milestone, error) {
	rows, err := tx.Query(`SELECT rowid, session_id, at, text FROM session_milestones
		ORDER BY session_id, at DESC, rowid DESC`)
	if err != nil {
		return nil, fmt.Errorf("reading milestones: %w", err)
	}
	defer rows.Close()
	var out []Milestone
	for rows.Next() {
		var (
			m  Milestone
			at float64
		)
		if err := rows.Scan(&m.RowID, &m.SessionID, &at, &m.Text); err != nil {
			return nil, fmt.Errorf("reading milestones: %w", err)
		}
		m.At = fromReal(at)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading milestones: %w", err)
	}
	return out, nil
}

// InsertMilestone stores one state milestone; text must already be sealed.
func InsertMilestone(tx *sql.Tx, sessionID int64, at time.Time, text []byte) error {
	if _, err := tx.Exec(`INSERT INTO session_milestones (session_id, at, kind, text, ref) VALUES (?, ?, 'state', ?, NULL)`,
		sessionID, toReal(at), text); err != nil {
		return fmt.Errorf("storing a milestone: %w", err)
	}
	return nil
}

// DeleteMilestone removes one milestone by rowid.
func DeleteMilestone(tx *sql.Tx, rowID int64) error {
	if _, err := tx.Exec(`DELETE FROM session_milestones WHERE rowid = ?`, rowID); err != nil {
		return fmt.Errorf("deleting a milestone: %w", err)
	}
	return nil
}

// PruneMilestones drops the milestones older than before and any past a
// session's newest perSession (HubSyncState.pruneSessionMilestones).
func PruneMilestones(tx *sql.Tx, before time.Time, perSession int) error {
	if _, err := tx.Exec(`DELETE FROM session_milestones WHERE at < ?`, toReal(before)); err != nil {
		return fmt.Errorf("pruning milestones: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM session_milestones WHERE rowid IN (
		SELECT rowid FROM (
			SELECT rowid, ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY at DESC, rowid DESC) AS rank
			FROM session_milestones
		) WHERE rank > ?)`, perSession); err != nil {
		return fmt.Errorf("trimming milestones: %w", err)
	}
	return nil
}
