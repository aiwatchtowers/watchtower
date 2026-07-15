package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// GmailMessage is one row of gmail_messages.
type GmailMessage struct {
	ID           string
	ThreadID     string
	FromEmail    string
	FromName     string
	ToJSON       string
	CcJSON       string
	Subject      string
	Snippet      string
	BodyText     string
	InternalDate string
	LabelsJSON   string
	IsUnread     bool
	Permalink    string
	SyncedAt     string
	UpdatedAt    string
}

// GmailAuthState mirrors the singleton gmail_auth_state row.
type GmailAuthState struct {
	Status    string
	Error     string
	UpdatedAt string
}

// UpsertGmailMessage inserts or updates a message, stamping synced_at/updated_at.
func (db *DB) UpsertGmailMessage(m GmailMessage, syncedAt string) error {
	unread := 0
	if m.IsUnread {
		unread = 1
	}
	_, err := db.Exec(`INSERT INTO gmail_messages
        (id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
         body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
         thread_id=excluded.thread_id, from_email=excluded.from_email, from_name=excluded.from_name,
         to_json=excluded.to_json, cc_json=excluded.cc_json, subject=excluded.subject,
         snippet=excluded.snippet, body_text=excluded.body_text, internal_date=excluded.internal_date,
         labels_json=excluded.labels_json, is_unread=excluded.is_unread, permalink=excluded.permalink,
         synced_at=excluded.synced_at, updated_at=excluded.updated_at`,
		m.ID, m.ThreadID, m.FromEmail, m.FromName, m.ToJSON, m.CcJSON, m.Subject, m.Snippet,
		m.BodyText, m.InternalDate, m.LabelsJSON, unread, m.Permalink, syncedAt, syncedAt)
	if err != nil {
		return fmt.Errorf("upserting gmail message %s: %w", m.ID, err)
	}
	return nil
}

// GmailMessagesSyncedAfter returns messages whose synced_at is strictly after sinceISO.
func (db *DB) GmailMessagesSyncedAfter(sinceISO string) ([]GmailMessage, error) {
	rows, err := db.Query(`SELECT id, thread_id, from_email, from_name, to_json, cc_json,
        subject, snippet, body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
        FROM gmail_messages WHERE synced_at > ? ORDER BY internal_date ASC`, sinceISO)
	if err != nil {
		return nil, fmt.Errorf("querying gmail messages: %w", err)
	}
	defer rows.Close()
	var out []GmailMessage
	for rows.Next() {
		var m GmailMessage
		var unread int
		if err := rows.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON,
			&m.Subject, &m.Snippet, &m.BodyText, &m.InternalDate, &m.LabelsJSON, &unread,
			&m.Permalink, &m.SyncedAt, &m.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning gmail message: %w", err)
		}
		m.IsUnread = unread != 0
		out = append(out, m)
	}
	return out, rows.Err()
}

// GetGmailBodyByID returns the body_text of the gmail_messages row with the
// given id. A missing row is not an error: it returns ("", nil), since a
// signal's underlying gmail message may have been synced by a different
// pipeline path or since removed — callers should just fall back to the
// snippet in that case.
func (db *DB) GetGmailBodyByID(id string) (string, error) {
	var body string
	err := db.QueryRow(`SELECT body_text FROM gmail_messages WHERE id = ?`, id).Scan(&body)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting gmail body for %s: %w", id, err)
	}
	return body, nil
}

// GetGmailLastInternalDate returns the sync watermark (unix seconds, 0 if unset).
func (db *DB) GetGmailLastInternalDate() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(gmail_last_internal_date, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, nil
		}
		return 0, fmt.Errorf("getting gmail watermark: %w", err)
	}
	return ts, nil
}

// SetGmailLastInternalDate advances the sync watermark.
func (db *DB) SetGmailLastInternalDate(ts float64) error {
	res, err := db.Exec(`UPDATE workspace SET gmail_last_internal_date = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, ts)
	if err != nil {
		return fmt.Errorf("setting gmail watermark: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting gmail watermark: no workspace row exists")
	}
	return nil
}

// GetGmailAuthState reads the singleton auth telemetry row.
func (db *DB) GetGmailAuthState() (GmailAuthState, error) {
	var s GmailAuthState
	err := db.QueryRow(`SELECT status, error, updated_at FROM gmail_auth_state WHERE id = 1`).
		Scan(&s.Status, &s.Error, &s.UpdatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return GmailAuthState{Status: "ok"}, nil
		}
		return GmailAuthState{}, fmt.Errorf("reading gmail_auth_state: %w", err)
	}
	return s, nil
}

// SetGmailAuthState upserts auth telemetry. status is one of "ok", "revoked", "error".
func (db *DB) SetGmailAuthState(status, errMsg string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`INSERT INTO gmail_auth_state (id, status, error, updated_at)
        VALUES (1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status, error=excluded.error, updated_at=excluded.updated_at`,
		status, errMsg, now)
	if err != nil {
		return fmt.Errorf("upserting gmail_auth_state: %w", err)
	}
	return nil
}
