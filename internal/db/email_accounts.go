package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
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

// CreateEmailAccount inserts a new connected mailbox and returns its ID. An
// empty a.Label gets the automatic label (MailAccountLabel).
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
	db.fillAccountLabelBestEffort("email_accounts", id, MailAccountLabel(a.EmailAddress, a.Host))
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

// UpsertImapMessage inserts or updates a message, stamping synced_at from
// syncedAt and updated_at with the write time (R18: a backfilled row keeps
// its own date as synced_at but must still reach the knowledge index).
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
		m.BodyText, m.InternalDate, unread, m.Permalink, syncedAt, time.Now().UTC().Format(time.RFC3339))
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

// ImapStoredUIDs returns the UIDs stored for accountID under one UIDVALIDITY.
func (db *DB) ImapStoredUIDs(accountID, uidValidity int64) ([]int64, error) {
	rows, err := db.Query(`SELECT uid FROM imap_messages WHERE account_id = ? AND uidvalidity = ?`,
		accountID, uidValidity)
	if err != nil {
		return nil, fmt.Errorf("listing stored imap uids for account %d: %w", accountID, err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var u int64
		if err := rows.Scan(&u); err != nil {
			return nil, fmt.Errorf("scanning imap uid: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// DeleteImapMessages removes the given UIDs of one (account, UIDVALIDITY) in a
// single transaction, using IN lists of at most 500. Returns the rows deleted.
func (db *DB) DeleteImapMessages(accountID, uidValidity int64, uids []int64) (int, error) {
	if len(uids) == 0 {
		return 0, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("deleting imap messages for account %d: %w", accountID, err)
	}
	defer func() { _ = tx.Rollback() }()
	total := 0
	const chunk = 500
	for start := 0; start < len(uids); start += chunk {
		end := min(start+chunk, len(uids))
		part := uids[start:end]
		args := make([]any, 0, len(part)+2)
		args = append(args, accountID, uidValidity)
		for _, u := range part {
			args = append(args, u)
		}
		//nolint:gosec // G202: the concatenation is only "?" placeholders; every value is a bound arg.
		res, err := tx.Exec(`DELETE FROM imap_messages WHERE account_id = ? AND uidvalidity = ? AND uid IN (`+
			strings.TrimSuffix(strings.Repeat("?,", len(part)), ",")+`)`, args...)
		if err != nil {
			return 0, fmt.Errorf("deleting imap messages for account %d: %w", accountID, err)
		}
		n, _ := res.RowsAffected()
		total += int(n)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("deleting imap messages for account %d: %w", accountID, err)
	}
	return total, nil
}

// DeleteImapMessagesOutsideUIDValidity removes the account's rows stored under
// any UIDVALIDITY other than the current one: after the server recreated the
// mailbox they name nothing on it.
func (db *DB) DeleteImapMessagesOutsideUIDValidity(accountID, uidValidity int64) (int, error) {
	res, err := db.Exec(`DELETE FROM imap_messages WHERE account_id = ? AND uidvalidity <> ?`,
		accountID, uidValidity)
	if err != nil {
		return 0, fmt.Errorf("deleting stale-epoch imap messages for account %d: %w", accountID, err)
	}
	n, _ := res.RowsAffected()
	return int(n), nil
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

// imapTSUnixExpr decodes imap_messages.internal_date (RFC3339 UTC, written by
// internal/imap) to whole unix seconds — the gmailTSUnixExpr twin.
const imapTSUnixExpr = `CAST(strftime('%s', internal_date) AS INTEGER)`

// imapCurrentEpoch keeps only rows stored under the mailbox's current
// UIDVALIDITY (email_accounts.uidvalidity). A UIDVALIDITY reset re-downloads
// the mailbox under new UIDs while the old rows stay stored, so without this
// the ideas pass would mine the same mail twice under two refs.
const imapCurrentEpoch = `uidvalidity = (SELECT ea.uidvalidity FROM email_accounts ea WHERE ea.id = imap_messages.account_id)`

// ListImapMessagesForExtract returns accountID's imap_messages with a decoded
// internal_date strictly above sinceTS (and at or below beforeTS when it is
// non-zero), oldest first, capped at limit with the same boundary-second
// drain as ListGmailThreadsForExtract — the input of the ideas email
// pre-digest for an IMAP/Outlook mailbox. IMAP stores no thread id, so every
// message is its own thread: MessageID and ThreadID are both
// "<uidvalidity>-<uid>", unique within the mailbox. A message with no date is
// never returned (no floor can be placed on it), nor one stored under an
// earlier UIDVALIDITY (imapCurrentEpoch).
func (db *DB) ListImapMessagesForExtract(accountID int64, sinceTS, beforeTS float64, limit int) ([]GmailExtractMessage, error) {
	return listExtractDrainingBoundary(func(op string, tsArg, before float64, lim int) ([]GmailExtractMessage, error) {
		return db.queryImapExtractMessages(accountID, op, tsArg, before, lim)
	}, sinceTS, beforeTS, limit)
}

// queryImapExtractMessages is queryGmailExtractMessages over imap_messages.
// op is ">" or "=" (never user input); the ORDER BY ends in the primary key so
// a same-second group is ordered deterministically.
func (db *DB) queryImapExtractMessages(accountID int64, op string, tsArg, beforeTS float64, limit int) ([]GmailExtractMessage, error) {
	query := `
		SELECT uidvalidity || '-' || uid, subject, from_email, from_name, body_text, ` + imapTSUnixExpr + `
		FROM imap_messages
		WHERE account_id = ? AND internal_date != '' AND ` + imapCurrentEpoch + ` AND ` + imapTSUnixExpr + ` ` + op + ` ?`
	args := []any{accountID, tsArg}
	if beforeTS != 0 {
		query += ` AND ` + imapTSUnixExpr + ` <= ?`
		args = append(args, beforeTS)
	}
	query += `
		ORDER BY ` + imapTSUnixExpr + `, uidvalidity, uid
		LIMIT ?`
	args = append(args, limit)
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing imap messages for extract: %w", err)
	}
	defer rows.Close()

	var out []GmailExtractMessage
	for rows.Next() {
		var m GmailExtractMessage
		if err := rows.Scan(&m.MessageID, &m.Subject, &m.FromEmail, &m.FromName, &m.BodyText, &m.TSUnix); err != nil {
			return nil, fmt.Errorf("scanning imap extract message: %w", err)
		}
		m.ThreadID = m.MessageID
		out = append(out, m)
	}
	return out, rows.Err()
}

// ImapNewestMessageTS returns the decoded internal_date (unix seconds) of
// accountID's newest stored message, 0 when it has none — the IMAP stand-in
// for the Gmail sync watermark GetGmailAccountWatermark returns (the IMAP
// watermark is a UID, not a time).
func (db *DB) ImapNewestMessageTS(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(MAX(`+imapTSUnixExpr+`), 0) FROM imap_messages
		WHERE account_id = ? AND internal_date != '' AND `+imapCurrentEpoch, accountID).Scan(&ts)
	if err != nil {
		return 0, fmt.Errorf("getting newest imap message time for account %d: %w", accountID, err)
	}
	return ts, nil
}

// IdeasImapFloor returns the ideas registry's per-mailbox email pre-digest
// floor (unix seconds, email_accounts.ideas_email_floor) — the IdeasEmailFloor
// twin for IMAP/Outlook mailboxes. A missing mailbox reads as 0.
func (db *DB) IdeasImapFloor(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT ideas_email_floor FROM email_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting ideas imap floor for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetIdeasImapFloor sets the mailbox's ideas floor (see IdeasImapFloor).
func (db *DB) SetIdeasImapFloor(accountID int64, ts float64) error {
	res, err := db.Exec(`UPDATE email_accounts SET ideas_email_floor = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting ideas imap floor for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting ideas imap floor: no email_accounts row %d", accountID)
	}
	return nil
}
