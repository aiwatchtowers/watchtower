package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// stubGoogleAccountID is a placeholder google_accounts id used until this
// detector is threaded per-account (multi-account plan Task 8) —
// single-account installs always seed/migrate account id 1.
const stubGoogleAccountID = 1

// DetectGmail scans gmail_messages synced after sinceTS and creates one inbox
// item per message that involves myEmail. Trigger type is email_received when
// myEmail is a To recipient, otherwise email_cc (Cc only). Each message is
// deduplicated on (thread_id, message_id, trigger_type) so repeated calls are
// idempotent.
func DetectGmail(ctx context.Context, database *db.DB, myEmail string, sinceTS time.Time) (int, error) {
	if myEmail == "" {
		return 0, nil
	}
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	// GmailMessagesSyncedAfter fully drains its rows into a slice before we
	// issue any dedup/insert query below — required for in-memory SQLite with
	// MaxOpenConns(1) (see calendar_detector.go).
	msgs, err := database.GmailMessagesSyncedAfter(stubGoogleAccountID, sinceISO)
	if err != nil {
		return 0, fmt.Errorf("gmail_detector: query messages: %w", err)
	}

	created := 0
	for _, m := range msgs {
		var to, cc []string
		_ = json.Unmarshal([]byte(m.ToJSON), &to)
		_ = json.Unmarshal([]byte(m.CcJSON), &cc)

		trig := ""
		if containsEmailFold(to, myEmail) {
			trig = "email_received"
		} else if containsEmailFold(cc, myEmail) {
			trig = "email_cc"
		}
		if trig == "" {
			continue // message doesn't involve me
		}

		exists, err := gmailInboxExists(database, m.ThreadID, m.ID, trig)
		if err != nil {
			return created, fmt.Errorf("gmail_detector: dedup check: %w", err)
		}
		if exists {
			continue
		}

		snippet := m.Subject
		if m.Snippet != "" {
			snippet = m.Subject + " — " + m.Snippet
		}
		item := db.InboxItem{
			ChannelID:    m.ThreadID,
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
			return created, fmt.Errorf("gmail_detector: create inbox item for %s: %w", m.ID, err)
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

// gmailInboxExists dedups on (thread_id as channel_id, message_id as message_ts, trigger_type).
// Named uniquely to avoid symbol collisions with other detectors' *InboxExists helpers.
func gmailInboxExists(database *db.DB, threadID, messageID, triggerType string) (bool, error) {
	var count int
	err := database.QueryRow(`SELECT COUNT(*) FROM inbox_items
        WHERE channel_id = ? AND message_ts = ? AND trigger_type = ?`,
		threadID, messageID, triggerType).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}
