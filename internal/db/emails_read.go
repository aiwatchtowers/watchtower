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
// GetLocalEmail. Sent marks the owner's own sent mail: a Gmail row by
// GmailOwnSentSQL; an IMAP row only when its sender is the mailbox's own
// address (no Sent folder is synced, so only a self-addressed message).
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
	Sent         bool
}

// LocalEmailQuery filters ListLocalEmails. Since and Before are RFC 3339 UTC
// instants ("" = no bound) compared to internal_date, which both syncers
// store as UTC RFC 3339: Since inclusively, Before exclusively (paging older:
// Before = the oldest date of the previous page). Limit must be positive.
type LocalEmailQuery struct {
	Store      EmailStore
	AccountID  int64
	Since      string
	Before     string
	Limit      int
	UnreadOnly bool
}

// imapEmailIDExpr renders an imap_messages row's id (alias m) as
// "<uidvalidity>-<uid>".
const imapEmailIDExpr = `CAST(m.uidvalidity AS TEXT) || '-' || CAST(m.uid AS TEXT)`

// imapOwnSentSQL marks an imap_messages row (alias m) of the email_accounts
// row (alias a) sent by the mailbox's own address.
const imapOwnSentSQL = `(a.email_address <> '' AND lower(trim(m.from_email)) = lower(trim(a.email_address)))`

// The FROM clauses of the two stores, each row joined to its account row for
// the Sent mark.
const (
	gmailEmailFrom = ` FROM gmail_messages m JOIN google_accounts a ON a.id = m.account_id`
	imapEmailFrom  = ` FROM imap_messages m JOIN email_accounts a ON a.id = m.account_id`
)

// ListLocalEmails returns one account's synced messages, newest first,
// without their bodies. It reads only the local store.
func (db *DB) ListLocalEmails(ctx context.Context, q LocalEmailQuery) ([]LocalEmail, error) {
	if q.Limit <= 0 {
		return nil, fmt.Errorf("listing local emails: limit must be positive, got %d", q.Limit)
	}
	var query string
	switch q.Store {
	case EmailStoreGmail:
		query = `SELECT m.id, m.thread_id, m.from_email, m.from_name, m.to_json, m.cc_json, m.subject, m.snippet,
            m.internal_date, m.is_unread, m.permalink, ` + GmailOwnSentSQL("m", "a") + gmailEmailFrom + ` WHERE m.account_id = ?`
	case EmailStoreIMAP:
		query = `SELECT ` + imapEmailIDExpr + `, '', m.from_email, m.from_name, m.to_json, m.cc_json, m.subject, m.snippet,
            m.internal_date, m.is_unread, m.permalink, ` + imapOwnSentSQL + imapEmailFrom + ` WHERE m.account_id = ?`
	default:
		return nil, fmt.Errorf("listing local emails: unknown store %q", q.Store)
	}
	args := []any{q.AccountID}
	if q.Since != "" {
		query += ` AND m.internal_date >= ?`
		args = append(args, q.Since)
	}
	if q.Before != "" {
		query += ` AND m.internal_date < ?`
		args = append(args, q.Before)
	}
	if q.UnreadOnly {
		query += ` AND m.is_unread = 1`
	}
	if q.Store == EmailStoreGmail {
		query += ` ORDER BY m.internal_date DESC, m.id DESC LIMIT ?`
	} else {
		query += ` ORDER BY m.internal_date DESC, m.uidvalidity DESC, m.uid DESC LIMIT ?`
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
			&m.Subject, &m.Snippet, &m.InternalDate, &unread, &m.Permalink, &m.Sent); err != nil {
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
		row = db.QueryRowContext(ctx, `SELECT m.id, m.thread_id, m.from_email, m.from_name, m.to_json, m.cc_json, m.subject,
            m.snippet, m.body_text, m.internal_date, m.is_unread, m.permalink, `+GmailOwnSentSQL("m", "a")+
			gmailEmailFrom+` WHERE m.account_id = ? AND m.id = ?`, accountID, id)
	case EmailStoreIMAP:
		uidValidity, uid, ok := parseIMAPEmailID(id)
		if !ok {
			return LocalEmail{}, false, nil
		}
		row = db.QueryRowContext(ctx, `SELECT `+imapEmailIDExpr+`, '', m.from_email, m.from_name, m.to_json, m.cc_json,
            m.subject, m.snippet, m.body_text, m.internal_date, m.is_unread, m.permalink, `+imapOwnSentSQL+
			imapEmailFrom+` WHERE m.account_id = ? AND m.uidvalidity = ? AND m.uid = ?`, accountID, uidValidity, uid)
	default:
		return LocalEmail{}, false, fmt.Errorf("getting local email: unknown store %q", store)
	}
	var unread int
	err = row.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON, &m.Subject,
		&m.Snippet, &m.BodyText, &m.InternalDate, &unread, &m.Permalink, &m.Sent)
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
