package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
)

// GmailChannelPrefix returns the inbox channel_id prefix shared by every
// Gmail-derived row of accountID. It is the single source of truth for the
// account half of a Gmail channel id — a per-account purge filters on it, and
// GmailChannelID builds the full id from it.
func GmailChannelPrefix(accountID int64) string {
	return fmt.Sprintf("gmail:%d", accountID)
}

// GmailChannelID returns the inbox channel_id for one Gmail thread of
// accountID: "gmail:<account-id>:<thread-id>".
func GmailChannelID(accountID int64, threadID string) string {
	return GmailChannelPrefix(accountID) + ":" + threadID
}

// ClearGmailData removes the Gmail data synced for one account on the user's
// request: its gmail_messages rows, the inbox items its detector minted (their
// inbox_feedback and situation_signals rows cascade via FK), the situations and
// feed rows those signals leave orphaned, and the learned rules scoped to its
// channel ids. Every other account's rows are untouched, and so is the rest of
// the inbox.
//
// Only "channel:gmail:<id>:<thread>" learned rules go — they name one thread of
// one account and can never match again once that account's items are gone,
// mirroring how ClearSlackData drops channel-scoped rules on disconnect.
// "sender:<email>" rules stay: a sender is an identity, not an account, and the
// same correspondent may well be writing to another connected mailbox.
//
// Watermarks are deliberately preserved — none of google_accounts'
// gmail_last_internal_date / memory_gmail_last_extracted_ts nor workspace's
// inbox_last_processed_ts / compose_last_run_ts is reset. Rewinding the sync
// watermark would re-download the very mail that was just deleted; rewinding
// the memory one would re-extract against an empty table and thin out episodes
// already accumulated; the inbox and composer watermarks are shared with the
// Slack, Jira, and calendar sources.
//
// The memory vault and the memory_* tables are likewise left alone: derived
// knowledge is preserved by design, and its dangling mail: provenance refs are
// safe because they are validated at write time only, never at read.
func (db *DB) ClearGmailData(accountID int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning gmail purge: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	prefix := GmailChannelPrefix(accountID)

	// The situations this account's Gmail signals feed, captured before the
	// signals go away: situation_signals cascades off inbox_items, so once the
	// items are deleted the link no longer exists. Only these situations are
	// candidates for the orphan sweep below. ClearSlackData can sweep every
	// signal-less situation because it is a whole-source disconnect; a purge
	// scoped to one Gmail account must not, since a signal-less situation is a
	// legitimate state — the composer mints target_update/track_update
	// situations from "tgt:"/"evt:" material that never becomes a membership
	// link (see signalMemberIDs in internal/inbox/compose.go).
	touched, err := situationsWithGmailSignals(tx, prefix)
	if err != nil {
		return err
	}

	// Raw synced mail for this account.
	if _, err := tx.Exec(`DELETE FROM gmail_messages WHERE account_id = ?`, accountID); err != nil {
		return fmt.Errorf("gmail purge: deleting messages: %w", err)
	}
	// This account's Gmail inbox signals. inbox_feedback and situation_signals
	// rows cascade via FK.
	if _, err := tx.Exec(`DELETE FROM inbox_items WHERE channel_id LIKE ? || ':%'`, prefix); err != nil {
		return fmt.Errorf("gmail purge: deleting inbox items: %w", err)
	}
	// Learned rules keyed to this account's Gmail channel ids.
	if _, err := tx.Exec(`DELETE FROM inbox_learned_rules
		WHERE scope_key LIKE 'channel:' || ? || ':%'`, prefix); err != nil {
		return fmt.Errorf("gmail purge: deleting learned rules: %w", err)
	}

	// Touched situations left with no signals at all, then the feed rows whose
	// source situation is gone.
	for _, id := range touched {
		if _, err := tx.Exec(`DELETE FROM situations WHERE id = ?
			AND id NOT IN (SELECT situation_id FROM situation_signals)`, id); err != nil {
			return fmt.Errorf("gmail purge: deleting orphaned situation %d: %w", id, err)
		}
		if _, err := tx.Exec(`DELETE FROM feed_items WHERE item_type = 'situation'
			AND source_id = ?
			AND source_id NOT IN (SELECT CAST(id AS TEXT) FROM situations)`,
			strconv.FormatInt(id, 10)); err != nil {
			return fmt.Errorf("gmail purge: deleting orphaned feed item %d: %w", id, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing gmail purge: %w", err)
	}
	return nil
}

// situationsWithGmailSignals returns the ids of the situations holding at
// least one signal whose channel_id carries prefix. The rows are drained
// before returning so the caller's transaction can issue further statements
// (required with MaxOpenConns(1)).
func situationsWithGmailSignals(tx *sql.Tx, prefix string) ([]int64, error) {
	rows, err := tx.Query(`SELECT DISTINCT ss.situation_id
		FROM situation_signals ss
		JOIN inbox_items i ON i.id = ss.inbox_item_id
		WHERE i.channel_id LIKE ? || ':%'`, prefix)
	if err != nil {
		return nil, fmt.Errorf("gmail purge: listing affected situations: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("gmail purge: scanning affected situation: %w", err)
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("gmail purge: listing affected situations: %w", err)
	}
	return out, nil
}

// GmailMessage is one row of gmail_messages.
type GmailMessage struct {
	ID           string
	ThreadID     string
	FromEmail    string
	FromName     string
	ToJSON       string
	CcJSON       string
	Subject      string
	Snippet      string
	BodyText     string
	InternalDate string
	LabelsJSON   string
	IsUnread     bool
	Permalink    string
	SyncedAt     string
	UpdatedAt    string
}

// UpsertGmailMessage inserts or updates a message for accountID, stamping
// synced_at/updated_at from m.SyncedAt. gmail_messages' primary key is
// (account_id, id) (migration 00043), so the same Gmail message id synced by
// two different connected accounts is stored as two independent rows.
func (db *DB) UpsertGmailMessage(accountID int64, m GmailMessage) error {
	unread := 0
	if m.IsUnread {
		unread = 1
	}
	_, err := db.Exec(`INSERT INTO gmail_messages
        (account_id, id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
         body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(account_id, id) DO UPDATE SET
         thread_id=excluded.thread_id, from_email=excluded.from_email, from_name=excluded.from_name,
         to_json=excluded.to_json, cc_json=excluded.cc_json, subject=excluded.subject,
         snippet=excluded.snippet, body_text=excluded.body_text, internal_date=excluded.internal_date,
         labels_json=excluded.labels_json, is_unread=excluded.is_unread, permalink=excluded.permalink,
         synced_at=excluded.synced_at, updated_at=excluded.updated_at`,
		accountID, m.ID, m.ThreadID, m.FromEmail, m.FromName, m.ToJSON, m.CcJSON, m.Subject, m.Snippet,
		m.BodyText, m.InternalDate, m.LabelsJSON, unread, m.Permalink, m.SyncedAt, m.SyncedAt)
	if err != nil {
		return fmt.Errorf("upserting gmail message %d/%s: %w", accountID, m.ID, err)
	}
	return nil
}

// GmailMessagesSyncedAfter returns accountID's messages whose synced_at is
// strictly after sinceISO.
func (db *DB) GmailMessagesSyncedAfter(accountID int64, sinceISO string) ([]GmailMessage, error) {
	rows, err := db.Query(`SELECT id, thread_id, from_email, from_name, to_json, cc_json,
        subject, snippet, body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
        FROM gmail_messages WHERE account_id = ? AND synced_at > ? ORDER BY internal_date ASC`,
		accountID, sinceISO)
	if err != nil {
		return nil, fmt.Errorf("querying gmail messages: %w", err)
	}
	defer rows.Close()
	var out []GmailMessage
	for rows.Next() {
		var m GmailMessage
		var unread int
		if err := rows.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON,
			&m.Subject, &m.Snippet, &m.BodyText, &m.InternalDate, &m.LabelsJSON, &unread,
			&m.Permalink, &m.SyncedAt, &m.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning gmail message: %w", err)
		}
		m.IsUnread = unread != 0
		out = append(out, m)
	}
	return out, rows.Err()
}

// GetGmailBodyByID returns the body_text of the gmail_messages row with the
// given id. A missing row is not an error: it returns ("", nil), since a
// signal's underlying gmail message may have been synced by a different
// pipeline path or since removed — callers should just fall back to the
// snippet in that case.
func (db *DB) GetGmailBodyByID(id string) (string, error) {
	var body string
	err := db.QueryRow(`SELECT body_text FROM gmail_messages WHERE id = ?`, id).Scan(&body)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting gmail body for %s: %w", id, err)
	}
	return body, nil
}
