package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// GoogleAccount is one row of google_accounts — a connected Google account
// (Calendar and/or Gmail), the Google analog of EmailAccount/CalendarAccount.
// Replaces the calendar_auth_state/gmail_auth_state singletons: Status/Error
// here are the per-account auth telemetry, and GmailLastInternalDate/
// MemoryGmailLastExtractedTS are the per-account watermarks that used to live
// as workspace scalars (see migration 00043).
type GoogleAccount struct {
	ID                         int64
	Email                      string
	Label                      string
	ClientID                   string
	CalendarEnabled            bool
	GmailEnabled               bool
	Status                     string // "ok" | "error" | "revoked"
	Error                      string
	GmailLastInternalDate      float64
	MemoryGmailLastExtractedTS float64
	CreatedAt                  string
	UpdatedAt                  string
}

// CreateGoogleAccount inserts a new connected Google account and returns its ID.
func (db *DB) CreateGoogleAccount(a GoogleAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO google_accounts
        (email, label, client_id, calendar_enabled, gmail_enabled)
        VALUES (?,?,?,?,?)`,
		a.Email, a.Label, a.ClientID, a.CalendarEnabled, a.GmailEnabled)
	if err != nil {
		return 0, fmt.Errorf("creating google account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new google account id: %w", err)
	}
	return id, nil
}

// ListGoogleAccounts returns every connected Google account, oldest first.
func (db *DB) ListGoogleAccounts() ([]GoogleAccount, error) {
	rows, err := db.Query(`SELECT id, email, label, client_id, calendar_enabled, gmail_enabled,
        status, error, gmail_last_internal_date, memory_gmail_last_extracted_ts, created_at, updated_at
        FROM google_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing google accounts: %w", err)
	}
	defer rows.Close()
	var out []GoogleAccount
	for rows.Next() {
		var a GoogleAccount
		if err := rows.Scan(&a.ID, &a.Email, &a.Label, &a.ClientID, &a.CalendarEnabled, &a.GmailEnabled,
			&a.Status, &a.Error, &a.GmailLastInternalDate, &a.MemoryGmailLastExtractedTS,
			&a.CreatedAt, &a.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning google account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetGoogleAccount returns a single connected Google account by ID.
func (db *DB) GetGoogleAccount(id int64) (GoogleAccount, error) {
	var a GoogleAccount
	err := db.QueryRow(`SELECT id, email, label, client_id, calendar_enabled, gmail_enabled,
        status, error, gmail_last_internal_date, memory_gmail_last_extracted_ts, created_at, updated_at
        FROM google_accounts WHERE id = ?`, id).
		Scan(&a.ID, &a.Email, &a.Label, &a.ClientID, &a.CalendarEnabled, &a.GmailEnabled,
			&a.Status, &a.Error, &a.GmailLastInternalDate, &a.MemoryGmailLastExtractedTS,
			&a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return GoogleAccount{}, fmt.Errorf("getting google account %d: %w", id, err)
	}
	return a, nil
}

// UpdateGoogleAccountConnection updates the resolved email and enabled
// services for accountID — called once the OAuth grant resolves which
// services were actually approved and the account's email address.
func (db *DB) UpdateGoogleAccountConnection(id int64, email string, calendarEnabled, gmailEnabled bool) error {
	res, err := db.Exec(`UPDATE google_accounts SET email = ?, calendar_enabled = ?, gmail_enabled = ?,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		email, calendarEnabled, gmailEnabled, id)
	if err != nil {
		return fmt.Errorf("updating google account %d connection: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("updating google account connection: no google_accounts row %d", id)
	}
	return nil
}

// DeleteGoogleAccount removes a connected Google account along with its
// calendar_calendars rows and their calendar_events, so a removed account
// leaves no ghost events behind (mirroring DeleteCalendarAccount). Its
// gmail_messages rows cascade via ON DELETE CASCADE. Deleting the events
// cascades meeting_prep_cache and SET-NULLs meeting_transcripts exactly as
// DeleteCalendarAccount already relies on. Deleting a missing account is a
// no-op, mirroring DeleteEmailAccount/DeleteCalendarAccount.
func (db *DB) DeleteGoogleAccount(id int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("deleting google account %d: %w", id, err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM calendar_events WHERE calendar_id IN
	        (SELECT id FROM calendar_calendars WHERE account_id = ?)`, id); err != nil {
		return fmt.Errorf("deleting google account %d events: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM calendar_calendars WHERE account_id = ?`, id); err != nil {
		return fmt.Errorf("deleting google account %d calendars: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM google_accounts WHERE id = ?`, id); err != nil {
		return fmt.Errorf("deleting google account %d: %w", id, err)
	}
	return tx.Commit()
}

// SetGoogleAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "revoked", "error".
func (db *DB) SetGoogleAccountAuthState(accountID int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE google_accounts SET status = ?, error = ?,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		status, errMsg, accountID)
	if err != nil {
		return fmt.Errorf("setting auth state for google account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting auth state: no google_accounts row %d", accountID)
	}
	return nil
}

// GetGmailAccountWatermark returns the Gmail sync watermark (unix seconds, 0
// if unset or the account is missing) for accountID — the per-account
// replacement for the old workspace.gmail_last_internal_date scalar.
func (db *DB) GetGmailAccountWatermark(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT gmail_last_internal_date FROM google_accounts WHERE id = ?`, accountID).Scan(&ts)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, nil
		}
		return 0, fmt.Errorf("getting gmail watermark for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetGmailAccountWatermark advances the Gmail sync watermark for accountID.
func (db *DB) SetGmailAccountWatermark(accountID int64, ts float64) error {
	res, err := db.Exec(`UPDATE google_accounts SET gmail_last_internal_date = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting gmail watermark for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting gmail watermark: no google_accounts row %d", accountID)
	}
	return nil
}
