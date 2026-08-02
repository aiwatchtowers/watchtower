package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// EmailAccount is one row of email_accounts — a connected IMAP or Outlook mailbox.
type EmailAccount struct {
	ID           int64
	Provider     string // "imap" | "outlook"
	EmailAddress string
	Host         string
	Port         int
	Security     string // "ssl" | "starttls" | "none"
	Folder       string
	Label        string
	Status       string // "ok" | "error" | "revoked"
	Error        string
	LastUID      int64
	UIDValidity  int64
	CreatedAt    string
	UpdatedAt    string
}

// ImapMessage is one row of imap_messages.
type ImapMessage struct {
	AccountID    int64
	UID          int64
	UIDValidity  int64
	FromEmail    string
	FromName     string
	ToJSON       string
	CcJSON       string
	Subject      string
	Snippet      string
	BodyText     string
	InternalDate string
	IsUnread     bool
	// Permalink is intentionally always empty for IMAP/Outlook-sourced
	// messages: unlike Gmail's mail.google.com web UI, generic IMAP has no
	// universal, cross-client deep-link URL scheme to construct one from.
	// The Dashboard already handles this gracefully — DashboardViewModel's
	// slackURL(for:) guards on `!item.permalink.isEmpty` and simply returns
	// nil (no link affordance shown) rather than rendering a broken button.
	Permalink string
	SyncedAt  string
	UpdatedAt string
}

// CreateEmailAccount inserts a new connected mailbox and returns its ID.
func (db *DB) CreateEmailAccount(a EmailAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO email_accounts
        (provider, email_address, host, port, security, folder, label)
        VALUES (?,?,?,?,?,?,?)`,
		a.Provider, a.EmailAddress, a.Host, a.Port, a.Security, a.Folder, a.Label)
	if err != nil {
		return 0, fmt.Errorf("creating email account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new email account id: %w", err)
	}
	return id, nil
}

// ListEmailAccounts returns every connected mailbox (imap and outlook), oldest first.
func (db *DB) ListEmailAccounts() ([]EmailAccount, error) {
	rows, err := db.Query(`SELECT id, provider, email_address, host, port, security, folder,
        label, status, error, last_uid, uidvalidity, created_at, updated_at
        FROM email_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing email accounts: %w", err)
	}
	defer rows.Close()
	var out []EmailAccount
	for rows.Next() {
		var a EmailAccount
		if err := rows.Scan(&a.ID, &a.Provider, &a.EmailAddress, &a.Host, &a.Port, &a.Security,
			&a.Folder, &a.Label, &a.Status, &a.Error, &a.LastUID, &a.UIDValidity,
			&a.CreatedAt, &a.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning email account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetEmailAccount returns a single connected mailbox by ID.
func (db *DB) GetEmailAccount(id int64) (EmailAccount, error) {
	var a EmailAccount
	err := db.QueryRow(`SELECT id, provider, email_address, host, port, security, folder,
        label, status, error, last_uid, uidvalidity, created_at, updated_at
        FROM email_accounts WHERE id = ?`, id).
		Scan(&a.ID, &a.Provider, &a.EmailAddress, &a.Host, &a.Port, &a.Security,
			&a.Folder, &a.Label, &a.Status, &a.Error, &a.LastUID, &a.UIDValidity,
			&a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return EmailAccount{}, fmt.Errorf("getting email account %d: %w", id, err)
	}
	return a, nil
}

// DeleteEmailAccount removes a connected mailbox; its imap_messages rows cascade.
func (db *DB) DeleteEmailAccount(id int64) error {
	if _, err := db.Exec(`DELETE FROM email_accounts WHERE id = ?`, id); err != nil {
		return fmt.Errorf("deleting email account %d: %w", id, err)
	}
	return nil
}

// UpsertImapMessage inserts or updates a message, stamping synced_at/updated_at.
// The conflict target is (account_id, uidvalidity, uid) — the full primary
// key — so a UID reused under a different UIDVALIDITY epoch (a real message,
// after the server recreates the mailbox) is stored as its own row rather
// than overwriting the pre-reset message that happened to share the same UID.
func (db *DB) UpsertImapMessage(m ImapMessage, syncedAt string) error {
	unread := 0
	if m.IsUnread {
		unread = 1
	}
	_, err := db.Exec(`INSERT INTO imap_messages
        (account_id, uid, uidvalidity, from_email, from_name, to_json, cc_json, subject, snippet,
         body_text, internal_date, is_unread, permalink, synced_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(account_id, uidvalidity, uid) DO UPDATE SET
         from_email=excluded.from_email, from_name=excluded.from_name,
         to_json=excluded.to_json, cc_json=excluded.cc_json, subject=excluded.subject,
         snippet=excluded.snippet, body_text=excluded.body_text, internal_date=excluded.internal_date,
         is_unread=excluded.is_unread, permalink=excluded.permalink,
         synced_at=excluded.synced_at, updated_at=excluded.updated_at`,
		m.AccountID, m.UID, m.UIDValidity, m.FromEmail, m.FromName, m.ToJSON, m.CcJSON, m.Subject, m.Snippet,
		m.BodyText, m.InternalDate, unread, m.Permalink, syncedAt, syncedAt)
	if err != nil {
		return fmt.Errorf("upserting imap message %d/%d (uidvalidity %d): %w", m.AccountID, m.UID, m.UIDValidity, err)
	}
	return nil
}

// ImapMessagesSyncedAfter returns messages for accountID whose synced_at is strictly after sinceISO.
func (db *DB) ImapMessagesSyncedAfter(accountID int64, sinceISO string) ([]ImapMessage, error) {
	rows, err := db.Query(`SELECT account_id, uid, uidvalidity, from_email, from_name, to_json, cc_json,
        subject, snippet, body_text, internal_date, is_unread, permalink, synced_at, updated_at
        FROM imap_messages WHERE account_id = ? AND synced_at > ? ORDER BY internal_date ASC`,
		accountID, sinceISO)
	if err != nil {
		return nil, fmt.Errorf("querying imap messages: %w", err)
	}
	defer rows.Close()
	var out []ImapMessage
	for rows.Next() {
		var m ImapMessage
		var unread int
		if err := rows.Scan(&m.AccountID, &m.UID, &m.UIDValidity, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON,
			&m.Subject, &m.Snippet, &m.BodyText, &m.InternalDate, &unread,
			&m.Permalink, &m.SyncedAt, &m.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning imap message: %w", err)
		}
		m.IsUnread = unread != 0
		out = append(out, m)
	}
	return out, rows.Err()
}

// GetImapWatermark returns the sync watermark (last_uid, uidvalidity) for accountID.
func (db *DB) GetImapWatermark(accountID int64) (lastUID, uidValidity int64, err error) {
	err = db.QueryRow(`SELECT last_uid, uidvalidity FROM email_accounts WHERE id = ?`, accountID).
		Scan(&lastUID, &uidValidity)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, 0, nil
		}
		return 0, 0, fmt.Errorf("getting imap watermark for account %d: %w", accountID, err)
	}
	return lastUID, uidValidity, nil
}

// SetImapWatermark advances the sync watermark for accountID.
func (db *DB) SetImapWatermark(accountID, lastUID, uidValidity int64) error {
	res, err := db.Exec(`UPDATE email_accounts SET last_uid = ?, uidvalidity = ?,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		lastUID, uidValidity, accountID)
	if err != nil {
		return fmt.Errorf("setting imap watermark for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting imap watermark: no email_accounts row %d", accountID)
	}
	return nil
}

// SetEmailAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "revoked", "error".
func (db *DB) SetEmailAccountAuthState(accountID int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE email_accounts SET status = ?, error = ?,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		status, errMsg, accountID)
	if err != nil {
		return fmt.Errorf("setting auth state for email account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting auth state: no email_accounts row %d", accountID)
	}
	return nil
}
