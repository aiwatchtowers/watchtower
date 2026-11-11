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

// GmailItemsAnsweredByOwner returns the ids of the pending Gmail
// email_received inbox items whose thread holds an owner sent row (see
// GmailOwnSent) newer than the received message. The received message's
// internal_date is the reference; when its row is gone or its date does not
// parse, the item's created_at stands in. Dates are compared in Go (RFC 3339).
// Items whose channel_id is not a Gmail one are skipped. Any read error
// returns the error and no ids.
func (db *DB) GmailItemsAnsweredByOwner() ([]int, error) {
	candidates, err := db.pendingGmailReceivedItems()
	if err != nil {
		return nil, err
	}

	sentQuery := `SELECT MAX(m.internal_date) FROM gmail_messages m
		JOIN google_accounts a ON a.id = m.account_id
		WHERE m.thread_id = ? AND m.account_id = ? AND ` + GmailOwnSentSQL("m", "a")

	var out []int
	for _, c := range candidates {
		accountID, threadID, ok := ParseGmailChannelID(c.channelID)
		if !ok {
			continue
		}
		var received string
		err := db.QueryRow(`SELECT internal_date FROM gmail_messages WHERE account_id = ? AND id = ?`,
			accountID, c.messageTS).Scan(&received)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("reading received gmail message for item %d: %w", c.id, err)
		}
		since, perr := time.Parse(time.RFC3339, received)
		if perr != nil {
			if since, perr = time.Parse(time.RFC3339, c.createdAt); perr != nil {
				continue
			}
		}
		var sent sql.NullString
		if err := db.QueryRow(sentQuery, threadID, accountID).Scan(&sent); err != nil {
			return nil, fmt.Errorf("reading owner sent mail for item %d: %w", c.id, err)
		}
		if !sent.Valid {
			continue
		}
		sentAt, perr := time.Parse(time.RFC3339, sent.String)
		if perr != nil || !sentAt.After(since) {
			continue
		}
		out = append(out, c.id)
	}
	return out, nil
}

// gmailReceivedItem is one pending email_received inbox item.
type gmailReceivedItem struct {
	id                   int
	channelID, messageTS string
	createdAt            string
}

// pendingGmailReceivedItems reads every pending email_received item, fully
// drained before the caller issues any further query (single-connection
// SQLite).
func (db *DB) pendingGmailReceivedItems() ([]gmailReceivedItem, error) {
	rows, err := db.Query(`SELECT id, channel_id, message_ts, created_at FROM inbox_items
		WHERE trigger_type = 'email_received' AND status = 'pending'`)
	if err != nil {
		return nil, fmt.Errorf("listing pending gmail items: %w", err)
	}
	defer rows.Close()
	var out []gmailReceivedItem
	for rows.Next() {
		var c gmailReceivedItem
		if err := rows.Scan(&c.id, &c.channelID, &c.messageTS, &c.createdAt); err != nil {
			return nil, fmt.Errorf("scanning pending gmail item: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing pending gmail items: %w", err)
	}
	return out, nil
}
