package db

import (
	"fmt"
)

// SlackSyncMark is one channel's sync watermark as an automation event
// source snapshots it before phaseSlackSync and diffs it after.
type SlackSyncMark struct {
	LastSyncedTS        string
	InitialSyncComplete bool
}

// SlackChannelSyncMarks returns every channel's sync mark keyed by its
// namespaced channel id. Read-only.
func (db *DB) SlackChannelSyncMarks() (map[string]SlackSyncMark, error) {
	rows, err := db.Query(`SELECT channel_id, last_synced_ts, is_initial_sync_complete FROM sync_state`)
	if err != nil {
		return nil, fmt.Errorf("querying slack sync marks: %w", err)
	}
	defer rows.Close()
	marks := make(map[string]SlackSyncMark)
	for rows.Next() {
		var id string
		var m SlackSyncMark
		if err := rows.Scan(&id, &m.LastSyncedTS, &m.InitialSyncComplete); err != nil {
			return nil, fmt.Errorf("scanning slack sync mark: %w", err)
		}
		marks[id] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading slack sync marks: %w", err)
	}
	return marks, nil
}

// CountSlackMessagesAfter counts channelID's non-deleted messages with a ts
// after afterTS, leaving out excludeUserID's (the owner's own; "" excludes
// nobody). Read-only.
func (db *DB) CountSlackMessagesAfter(channelID, afterTS, excludeUserID string) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM messages
        WHERE channel_id = ? AND ts > ? AND is_deleted = 0 AND (? = '' OR user_id != ?)`,
		channelID, afterTS, excludeUserID, excludeUserID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting new messages in %s: %w", channelID, err)
	}
	return n, nil
}

// SlackEventLabels returns a Slack account's event label (its label, else
// its team domain) and the owner's namespaced user id on that account — a
// per-account read through GetSlackAccount, as OWNER-01 allows, since each
// account namespaces the owner differently. A missing account is an error.
// Read-only.
func (db *DB) SlackEventLabels(accountID int64) (account string, ownerUserID string, err error) {
	a, err := db.GetSlackAccount(accountID)
	if err != nil {
		return "", "", fmt.Errorf("reading slack event labels: %w", err)
	}
	if a.Label != "" {
		return a.Label, a.CurrentUserID, nil
	}
	return a.TeamDomain, a.CurrentUserID, nil
}

// mailLabelQueries are, per mail event provider, the account's label with
// the address as its fallback.
var mailLabelQueries = map[string]string{
	"gmail": `SELECT COALESCE(NULLIF(label, ''), email) FROM google_accounts WHERE id = ?`,
	"imap":  `SELECT COALESCE(NULLIF(label, ''), email_address) FROM email_accounts WHERE id = ?`,
}

// MailEventLabel returns a mail account's event label: its label, else its
// address. provider is "gmail" (google_accounts) or "imap" (email_accounts);
// a missing account or another provider is an error. Read-only.
func (db *DB) MailEventLabel(provider string, accountID int64) (string, error) {
	query, ok := mailLabelQueries[provider]
	if !ok {
		return "", fmt.Errorf("mail event label: unknown provider %q", provider)
	}
	var label string
	if err := db.QueryRow(query, accountID).Scan(&label); err != nil {
		return "", fmt.Errorf("reading %s account %d label: %w", provider, accountID, err)
	}
	return label, nil
}

// MailWatermarkSet reports whether a mail account has synced before — a
// non-zero Gmail internalDate or IMAP UID watermark. Read before the syncer
// runs, it tells an incremental sync (publish) from the initial backfill
// (publish nothing). A missing account reads as unset. Read-only.
func (db *DB) MailWatermarkSet(provider string, accountID int64) (bool, error) {
	switch provider {
	case "gmail":
		ts, err := db.GetGmailAccountWatermark(accountID)
		return ts > 0, err
	case "imap":
		uid, _, err := db.GetImapWatermark(accountID)
		return uid > 0, err
	default:
		return false, fmt.Errorf("mail watermark: unknown provider %q", provider)
	}
}
