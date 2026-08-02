package db

import (
	"database/sql"
	"errors"
	"fmt"
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

// UpsertGmailMessage inserts or updates a message for accountID, stamping
// synced_at/updated_at from m.SyncedAt. gmail_messages' primary key is
// (account_id, id) (migration 00043), so the same Gmail message id synced by
// two different connected accounts is stored as two independent rows.
func (db *DB) UpsertGmailMessage(accountID int64, m GmailMessage) error {
	unread := 0
	if m.IsUnread {
		unread = 1
	}
	_, err := db.Exec(`INSERT INTO gmail_messages
        (account_id, id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
         body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(account_id, id) DO UPDATE SET
         thread_id=excluded.thread_id, from_email=excluded.from_email, from_name=excluded.from_name,
         to_json=excluded.to_json, cc_json=excluded.cc_json, subject=excluded.subject,
         snippet=excluded.snippet, body_text=excluded.body_text, internal_date=excluded.internal_date,
         labels_json=excluded.labels_json, is_unread=excluded.is_unread, permalink=excluded.permalink,
         synced_at=excluded.synced_at, updated_at=excluded.updated_at`,
		accountID, m.ID, m.ThreadID, m.FromEmail, m.FromName, m.ToJSON, m.CcJSON, m.Subject, m.Snippet,
		m.BodyText, m.InternalDate, m.LabelsJSON, unread, m.Permalink, m.SyncedAt, m.SyncedAt)
	if err != nil {
		return fmt.Errorf("upserting gmail message %d/%s: %w", accountID, m.ID, err)
	}
	return nil
}

// GmailMessagesSyncedAfter returns accountID's messages whose synced_at is
// strictly after sinceISO.
func (db *DB) GmailMessagesSyncedAfter(accountID int64, sinceISO string) ([]GmailMessage, error) {
	rows, err := db.Query(`SELECT id, thread_id, from_email, from_name, to_json, cc_json,
        subject, snippet, body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
        FROM gmail_messages WHERE account_id = ? AND synced_at > ? ORDER BY internal_date ASC`,
		accountID, sinceISO)
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
