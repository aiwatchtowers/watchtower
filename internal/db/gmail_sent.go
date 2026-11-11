package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// GmailSentLabel is the Gmail system label on every message the mailbox owner
// sent.
const GmailSentLabel = "SENT"

// GmailOwnSent reports whether a gmail_messages row is the owner's own sent
// mail: its labels carry SENT, or its sender is the account's own address.
// labelsJSON is the stored JSON array; the test is a substring match on the
// quoted label so a user label id that merely contains SENT never counts.
// GmailOwnSentSQL is its SQL twin; the two must decide every row alike.
func GmailOwnSent(labelsJSON, fromEmail, accountEmail string) bool {
	if strings.Contains(labelsJSON, `"`+GmailSentLabel+`"`) {
		return true
	}
	account := strings.TrimSpace(accountEmail)
	return account != "" && strings.EqualFold(strings.TrimSpace(fromEmail), account)
}

// GmailOwnSentSQL returns the SQL twin of GmailOwnSent over the table aliases
// msg (a gmail_messages row) and acct (its google_accounts row). Callers pass
// fixed aliases only, never user input.
func GmailOwnSentSQL(msg, acct string) string {
	return `(` + msg + `.labels_json LIKE '%"` + GmailSentLabel + `"%' OR (` + acct + `.email <> '' AND lower(trim(` +
		msg + `.from_email)) = lower(trim(` + acct + `.email))))`
}

// GmailSentCatchUpAt returns when the one-time Gmail sent catch-up finished
// for accountID as stored (RFC 3339 UTC); empty when not yet or when the account
// does not exist.
func (db *DB) GmailSentCatchUpAt(accountID int64) (string, error) {
	var s string
	err := db.QueryRow(`SELECT gmail_sent_catchup_at FROM google_accounts WHERE id = ?`, accountID).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting gmail sent catch-up stamp for account %d: %w", accountID, err)
	}
	return s, nil
}

// SetGmailSentCatchUpAt stamps the one-time Gmail sent catch-up as finished.
func (db *DB) SetGmailSentCatchUpAt(accountID int64, at time.Time) error {
	res, err := db.Exec(`UPDATE google_accounts SET gmail_sent_catchup_at = ? WHERE id = ?`,
		at.UTC().Format(time.RFC3339), accountID)
	if err != nil {
		return fmt.Errorf("setting gmail sent catch-up stamp for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting gmail sent catch-up stamp: no google_accounts row %d", accountID)
	}
	return nil
}
