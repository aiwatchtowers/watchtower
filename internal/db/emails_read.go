package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// EmailStore names the synced table an account's mail lives in: a Google
// account's in gmail_messages, an email_accounts mailbox's (IMAP, Outlook) in
// imap_messages.
type EmailStore string

const (
	EmailStoreGmail EmailStore = "gmail"
	EmailStoreIMAP  EmailStore = "imap"
)

// LocalEmail is one synced message as the automation email reads see it,
// for either store. ID is the Gmail message id, or "<uidvalidity>-<uid>" for
// an imap_messages row (ThreadID is empty there). BodyText is filled only by
// GetLocalEmail.
type LocalEmail struct {
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
	IsUnread     bool
	Permalink    string
}

// LocalEmailQuery filters ListLocalEmails. Since is an RFC 3339 UTC instant
// ("" = no lower bound), compared inclusively to internal_date, which both
// syncers store as UTC RFC 3339. Limit must be positive.
type LocalEmailQuery struct {
	Store      EmailStore
	AccountID  int64
	Since      string
	Limit      int
	UnreadOnly bool
}

// imapEmailIDExpr renders an imap_messages row's id as "<uidvalidity>-<uid>".
const imapEmailIDExpr = `CAST(uidvalidity AS TEXT) || '-' || CAST(uid AS TEXT)`

// ListLocalEmails returns one account's synced messages, newest first,
// without their bodies. It reads only the local store.
func (db *DB) ListLocalEmails(ctx context.Context, q LocalEmailQuery) ([]LocalEmail, error) {
	if q.Limit <= 0 {
		return nil, fmt.Errorf("listing local emails: limit must be positive, got %d", q.Limit)
	}
	var query string
	switch q.Store {
	case EmailStoreGmail:
		query = `SELECT id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
            internal_date, is_unread, permalink FROM gmail_messages WHERE account_id = ?`
	case EmailStoreIMAP:
		query = `SELECT ` + imapEmailIDExpr + `, '', from_email, from_name, to_json, cc_json, subject, snippet,
            internal_date, is_unread, permalink FROM imap_messages WHERE account_id = ?`
	default:
		return nil, fmt.Errorf("listing local emails: unknown store %q", q.Store)
	}
	args := []any{q.AccountID}
	if q.Since != "" {
		query += ` AND internal_date >= ?`
		args = append(args, q.Since)
	}
	if q.UnreadOnly {
		query += ` AND is_unread = 1`
	}
	if q.Store == EmailStoreGmail {
		query += ` ORDER BY internal_date DESC, id DESC LIMIT ?`
	} else {
		query += ` ORDER BY internal_date DESC, uidvalidity DESC, uid DESC LIMIT ?`
	}
	args = append(args, q.Limit)

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing local emails of %s account %d: %w", q.Store, q.AccountID, err)
	}
	defer rows.Close()
	out := []LocalEmail{}
	for rows.Next() {
		var m LocalEmail
		var unread int
		if err := rows.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON,
			&m.Subject, &m.Snippet, &m.InternalDate, &unread, &m.Permalink); err != nil {
			return nil, fmt.Errorf("scanning local email: %w", err)
		}
		m.IsUnread = unread != 0
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing local emails of %s account %d: %w", q.Store, q.AccountID, err)
	}
	return out, nil
}

// GetLocalEmail returns one synced message of an account with its body.
// found is false (and err nil) when the account has no such message —
// including an imap id that is not "<uidvalidity>-<uid>".
func (db *DB) GetLocalEmail(ctx context.Context, store EmailStore, accountID int64, id string) (m LocalEmail, found bool, err error) {
	var row *sql.Row
	switch store {
	case EmailStoreGmail:
		row = db.QueryRowContext(ctx, `SELECT id, thread_id, from_email, from_name, to_json, cc_json, subject,
            snippet, body_text, internal_date, is_unread, permalink
            FROM gmail_messages WHERE account_id = ? AND id = ?`, accountID, id)
	case EmailStoreIMAP:
		uidValidity, uid, ok := parseIMAPEmailID(id)
		if !ok {
			return LocalEmail{}, false, nil
		}
		row = db.QueryRowContext(ctx, `SELECT `+imapEmailIDExpr+`, '', from_email, from_name, to_json, cc_json,
            subject, snippet, body_text, internal_date, is_unread, permalink
            FROM imap_messages WHERE account_id = ? AND uidvalidity = ? AND uid = ?`, accountID, uidValidity, uid)
	default:
		return LocalEmail{}, false, fmt.Errorf("getting local email: unknown store %q", store)
	}
	var unread int
	err = row.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON, &m.Subject,
		&m.Snippet, &m.BodyText, &m.InternalDate, &unread, &m.Permalink)
	if errors.Is(err, sql.ErrNoRows) {
		return LocalEmail{}, false, nil
	}
	if err != nil {
		return LocalEmail{}, false, fmt.Errorf("getting local email %s of %s account %d: %w", id, store, accountID, err)
	}
	m.IsUnread = unread != 0
	return m, true, nil
}

// parseIMAPEmailID splits "<uidvalidity>-<uid>" (both non-negative integers).
func parseIMAPEmailID(id string) (uidValidity, uid int64, ok bool) {
	v, u, found := strings.Cut(id, "-")
	if !found {
		return 0, 0, false
	}
	uidValidity, errV := strconv.ParseInt(v, 10, 64)
	uid, errU := strconv.ParseInt(u, 10, 64)
	if errV != nil || errU != nil || uidValidity < 0 || uid < 0 {
		return 0, 0, false
	}
	return uidValidity, uid, true
}
