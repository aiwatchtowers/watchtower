package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"watchtower/internal/db"
)

// DetectImapAccounts scans imap_messages synced after sinceTS across every
// connected email_accounts row (imap and outlook alike — they share the same
// message table) and creates one inbox item per message that involves that
// account's own mailbox address. Mirrors DetectGmailAccounts' To/Cc matching and
// trigger-type logic, but channel_id embeds both the account ID and the
// message's own UIDVALIDITY epoch ("imap:<accountID>:<uidvalidity>:<folder>")
// since IMAP UIDs are only unique within one (account, uidvalidity) epoch —
// unlike Gmail's single mailbox, where thread_id alone is enough. A server-side
// UIDVALIDITY change (mailbox recreated) can reuse an old UID for an entirely
// different message; embedding the epoch per-message means the pre-reset and
// post-reset messages land under different channel_ids and can never dedup
// against each other, even if a resync interleaves both epochs' rows in one
// ImapMessagesSyncedAfter batch.
func DetectImapAccounts(ctx context.Context, database *db.DB, sinceTS time.Time) (int, error) {
	accounts, err := database.ListEmailAccounts()
	if err != nil {
		return 0, fmt.Errorf("imap_detector: listing accounts: %w", err)
	}
	sinceISO := sinceTS.UTC().Format(time.RFC3339)

	created := 0
	for _, acct := range accounts {
		if acct.EmailAddress == "" {
			continue // account has never completed a sync (no identity learned yet)
		}
		n, err := detectImapAccount(database, acct, sinceISO)
		if err != nil {
			return created, fmt.Errorf("imap_detector: account %d: %w", acct.ID, err)
		}
		created += n
	}
	return created, nil
}

func detectImapAccount(database *db.DB, acct db.EmailAccount, sinceISO string) (int, error) {
	// ImapMessagesSyncedAfter fully drains its rows into a slice before we
	// issue any dedup/insert query below — same in-memory SQLite constraint
	// as gmail_detector.go / calendar_detector.go (MaxOpenConns(1)).
	msgs, err := database.ImapMessagesSyncedAfter(acct.ID, sinceISO)
	if err != nil {
		return 0, fmt.Errorf("querying messages: %w", err)
	}

	created := 0
	for _, m := range msgs {
		channelID := fmt.Sprintf("imap:%d:%d:%s", acct.ID, m.UIDValidity, acct.Folder)
		var to, cc []string
		_ = json.Unmarshal([]byte(m.ToJSON), &to)
		_ = json.Unmarshal([]byte(m.CcJSON), &cc)

		trig := ""
		if containsEmailFold(to, acct.EmailAddress) {
			trig = "email_received"
		} else if containsEmailFold(cc, acct.EmailAddress) {
			trig = "email_cc"
		}
		if trig == "" {
			continue // message doesn't involve this account's own address
		}

		messageTS := strconv.FormatInt(m.UID, 10)
		exists, err := imapInboxExists(database, channelID, messageTS, trig)
		if err != nil {
			return created, fmt.Errorf("dedup check uid %d: %w", m.UID, err)
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
			MessageTS:    messageTS,
			SenderUserID: m.FromEmail,
			TriggerType:  trig,
			Snippet:      snippet,
			Permalink:    m.Permalink,
			ItemClass:    DefaultItemClass(trig),
			Status:       "pending",
			Priority:     "medium",
		}
		if _, err := database.CreateInboxItem(item); err != nil {
			return created, fmt.Errorf("create inbox item for uid %d: %w", m.UID, err)
		}
		created++
	}
	return created, nil
}

// imapInboxExists dedups on (channel_id, message_ts, trigger_type), matching
// gmailInboxExists' shape. Named uniquely to avoid symbol collisions with
// other detectors' *InboxExists helpers.
func imapInboxExists(database *db.DB, channelID, messageTS, triggerType string) (bool, error) {
	var count int
	err := database.QueryRow(`SELECT COUNT(*) FROM inbox_items
        WHERE channel_id = ? AND message_ts = ? AND trigger_type = ?`,
		channelID, messageTS, triggerType).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}
