package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// DetectGmailAccounts scans gmail_messages synced after sinceTS across every
// connected google_accounts row with Gmail enabled, and creates one inbox
// item per message that involves that account's own mailbox address.
// Mirrors DetectImapAccounts: an account with Gmail disabled or an
// unresolved (empty) email is skipped cleanly. Trigger type is
// email_received when the account's own email is a To recipient, otherwise
// email_cc (Cc only); a message FROM the account's own address (sent by the
// owner, not received) mints nothing. Each message is deduplicated on
// (channel_id, message_id, trigger_type) so repeated calls are idempotent.
func DetectGmailAccounts(ctx context.Context, database *db.DB, sinceTS time.Time) (int, error) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return 0, fmt.Errorf("gmail_detector: listing accounts: %w", err)
	}
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	created := 0
	for _, acct := range accounts {
		if !acct.GmailEnabled || acct.Email == "" {
			continue
		}
		n, err := detectGmailAccount(database, acct, sinceISO)
		if err != nil {
			return created, fmt.Errorf("gmail_detector: account %d: %w", acct.ID, err)
		}
		created += n
	}
	return created, nil
}

func detectGmailAccount(database *db.DB, acct db.GoogleAccount, sinceISO string) (int, error) {
	// GmailMessagesSyncedAfter fully drains its rows into a slice before we
	// issue any dedup/insert query below — required for in-memory SQLite with
	// MaxOpenConns(1) (see calendar_detector.go).
	msgs, err := database.GmailMessagesSyncedAfter(acct.ID, sinceISO)
	if err != nil {
		return 0, fmt.Errorf("querying messages: %w", err)
	}

	created := 0
	for _, m := range msgs {
		if strings.EqualFold(m.FromEmail, acct.Email) {
			continue // sent by this account's own owner, not received
		}

		var to, cc []string
		_ = json.Unmarshal([]byte(m.ToJSON), &to)
		_ = json.Unmarshal([]byte(m.CcJSON), &cc)

		trig := ""
		if containsEmailFold(to, acct.Email) {
			trig = "email_received"
		} else if containsEmailFold(cc, acct.Email) {
			trig = "email_cc"
		}
		if trig == "" {
			continue // message doesn't involve this account's own address
		}

		channelID := fmt.Sprintf("gmail:%d:%s", acct.ID, m.ThreadID)
		exists, err := gmailInboxExists(database, channelID, m.ID, trig)
		if err != nil {
			return created, fmt.Errorf("dedup check: %w", err)
		}
		if exists {
			continue
		}

		snippet := m.Subject
		if m.Snippet != "" {
			snippet = m.Subject + " — " + m.Snippet
		}
		item := db.InboxItem{
			ChannelID:    channelID,
			MessageTS:    m.ID,
			SenderUserID: m.FromEmail,
			TriggerType:  trig,
			Snippet:      snippet,
			Permalink:    m.Permalink,
			ItemClass:    DefaultItemClass(trig),
			Status:       "pending",
			Priority:     "medium",
		}
		if _, err := database.CreateInboxItem(item); err != nil {
			return created, fmt.Errorf("create inbox item for %s: %w", m.ID, err)
		}
		created++
	}
	return created, nil
}

// containsEmailFold reports whether target is present in addrs, comparing
// case-insensitively (email addresses are conventionally case-insensitive).
func containsEmailFold(addrs []string, target string) bool {
	for _, a := range addrs {
		if strings.EqualFold(a, target) {
			return true
		}
	}
	return false
}

// gmailInboxExists dedups on (channel_id, message_id as message_ts, trigger_type).
// Named uniquely to avoid symbol collisions with other detectors' *InboxExists helpers.
func gmailInboxExists(database *db.DB, channelID, messageID, triggerType string) (bool, error) {
	var count int
	err := database.QueryRow(`SELECT COUNT(*) FROM inbox_items
        WHERE channel_id = ? AND message_ts = ? AND trigger_type = ?`,
		channelID, messageID, triggerType).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}
