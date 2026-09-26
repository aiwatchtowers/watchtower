package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// CalendarAccount is one row of calendar_accounts — a connected CalDAV server
// or secret ICS feed. The exact calendar analog of EmailAccount.
type CalendarAccount struct {
	ID        int64
	Provider  string // "caldav" | "ics"
	Username  string
	URL       string // CalDAV server base URL only; empty for provider="ics" (the feed URL is a credential)
	Label     string
	Status    string // "ok" | "error" | "revoked"
	Error     string
	CreatedAt string
	UpdatedAt string
}

// CalendarAccountCalendarID returns the calendar_calendars/calendar_events
// calendar_id an account's events are scoped under: "caldav:<id>" / "ics:<id>".
// Shared by the caldav syncer (which registers the calendar row) and
// DeleteCalendarAccount (which cleans it up) so the two can't drift.
func CalendarAccountCalendarID(provider string, accountID int64) string {
	return fmt.Sprintf("%s:%d", provider, accountID)
}

// CreateCalendarAccount inserts a new connected calendar source and returns its ID.
func (db *DB) CreateCalendarAccount(a CalendarAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO calendar_accounts
        (provider, username, url, label)
        VALUES (?,?,?,?)`,
		a.Provider, a.Username, a.URL, a.Label)
	if err != nil {
		return 0, fmt.Errorf("creating calendar account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new calendar account id: %w", err)
	}
	return id, nil
}

// ListCalendarAccounts returns every connected calendar source (caldav and ics), oldest first.
func (db *DB) ListCalendarAccounts() ([]CalendarAccount, error) {
	rows, err := db.Query(`SELECT id, provider, username, url, label, status, error,
        created_at, updated_at
        FROM calendar_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing calendar accounts: %w", err)
	}
	defer rows.Close()
	var out []CalendarAccount
	for rows.Next() {
		var a CalendarAccount
		if err := rows.Scan(&a.ID, &a.Provider, &a.Username, &a.URL, &a.Label,
			&a.Status, &a.Error, &a.CreatedAt, &a.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning calendar account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetCalendarAccount returns a single connected calendar source by ID.
func (db *DB) GetCalendarAccount(id int64) (CalendarAccount, error) {
	var a CalendarAccount
	err := db.QueryRow(`SELECT id, provider, username, url, label, status, error,
        created_at, updated_at
        FROM calendar_accounts WHERE id = ?`, id).
		Scan(&a.ID, &a.Provider, &a.Username, &a.URL, &a.Label,
			&a.Status, &a.Error, &a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return CalendarAccount{}, fmt.Errorf("getting calendar account %d: %w", id, err)
	}
	return a, nil
}

// DeleteCalendarAccount removes a connected calendar source along with its
// calendar_calendars row and calendar_events, so a removed account leaves no
// ghost events behind. Events go first (calendar_events.calendar_id has a
// plain FK to calendar_calendars with no ON DELETE action, so the calendar
// row can't be dropped while events still reference it); the whole cleanup
// runs in one transaction. Deleting the events cascades meeting_prep_cache
// (ON DELETE CASCADE) and detaches meeting_transcripts (ON DELETE SET NULL) —
// transcripts outlive events by design.
func (db *DB) DeleteCalendarAccount(id int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning calendar account delete tx: %w", err)
	}
	defer tx.Rollback()

	var provider string
	err = tx.QueryRow(`SELECT provider FROM calendar_accounts WHERE id = ?`, id).Scan(&provider)
	if errors.Is(err, sql.ErrNoRows) {
		return nil // already gone — deleting a missing account is a no-op, mirroring DeleteEmailAccount
	}
	if err != nil {
		return fmt.Errorf("reading calendar account %d for delete: %w", id, err)
	}

	calID := CalendarAccountCalendarID(provider, id)
	if _, err := tx.Exec(`DELETE FROM calendar_events WHERE calendar_id = ?`, calID); err != nil {
		return fmt.Errorf("deleting calendar account %d events: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM calendar_calendars WHERE id = ?`, calID); err != nil {
		return fmt.Errorf("deleting calendar account %d calendar row: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM calendar_accounts WHERE id = ?`, id); err != nil {
		return fmt.Errorf("deleting calendar account %d: %w", id, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing calendar account %d delete: %w", id, err)
	}
	return nil
}

// SetCalendarAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "revoked", "error".
func (db *DB) SetCalendarAccountAuthState(accountID int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE calendar_accounts SET status = ?, error = ?,
        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		status, errMsg, accountID)
	if err != nil {
		return fmt.Errorf("setting auth state for calendar account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting auth state: no calendar_accounts row %d", accountID)
	}
	return nil
}
