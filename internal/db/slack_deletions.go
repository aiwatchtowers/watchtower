package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
)

// SlackMessageKey names one stored Slack message: the namespaced channel id
// ("<account>:<raw id>") and the Slack ts.
type SlackMessageKey struct{ ChannelID, TS string }

// LiveSlackMessageKeys lists the account's live, plain messages (empty subtype
// and not deleted) by a known human author with from <= ts_unix < to. These
// are the rows search.messages is expected to return: it never returns
// join/leave events, and app/bot posts (no user, or a bot user, honouring
// is_bot_override) may never reach it, so those are left out too, as is an
// author with no users row (most likely an app, bot or external user).
func (db *DB) LiveSlackMessageKeys(accountID int64, from, to float64) ([]SlackMessageKey, error) {
	prefix := strconv.FormatInt(accountID, 10)
	rows, err := db.Query(`SELECT m.channel_id, m.ts FROM messages m
		JOIN users u ON u.id = m.user_id
		WHERE m.channel_id >= ? AND m.channel_id < ? AND m.subtype = '' AND m.is_deleted = 0
		  AND m.ts_unix >= ? AND m.ts_unix < ?
		  AND COALESCE(u.is_bot_override, u.is_bot) = 0`, prefix+":", prefix+";", from, to)
	if err != nil {
		return nil, fmt.Errorf("listing live slack messages of account %d: %w", accountID, err)
	}
	defer rows.Close()
	var keys []SlackMessageKey
	for rows.Next() {
		var k SlackMessageKey
		if err := rows.Scan(&k.ChannelID, &k.TS); err != nil {
			return nil, fmt.Errorf("scanning live slack message: %w", err)
		}
		keys = append(keys, k)
	}
	return keys, rows.Err()
}

// TombstoneSlackMessages turns each live message into a tombstone in one
// transaction: is_deleted = 1, empty text and raw_json = "{}" (ts, user and
// thread_ts stay so threads and ids still resolve), and deletes its reactions
// and files rows. The inbox items made from the message stay, but their copies
// of its text (snippet, context, raw_text, and its entry in a channel item's
// mentions list) are blanked. FTS and kb_dirty follow through triggers. A key
// that is already a tombstone, or not stored, is skipped. Keys are written in
// transactions of at most tombstoneBatch, so no write holds the lock long. It
// returns how many rows were tombstoned (those of committed batches when a
// later batch fails).
func (db *DB) TombstoneSlackMessages(keys []SlackMessageKey) (int, error) {
	total := 0
	for start := 0; start < len(keys); start += tombstoneBatch {
		n, err := db.tombstoneSlackBatch(keys[start:min(start+tombstoneBatch, len(keys))])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// tombstoneBatch caps the keys one tombstone transaction writes.
const tombstoneBatch = 200

func (db *DB) tombstoneSlackBatch(keys []SlackMessageKey) (int, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin slack tombstone tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmts := []string{
		`DELETE FROM reactions WHERE channel_id = ? AND message_ts = ?`,
		`DELETE FROM files WHERE message_channel_id = ? AND message_ts = ?`,
		`UPDATE inbox_items SET snippet = '', context = '', raw_text = ''
		 WHERE channel_id = ? AND message_ts = ? AND (snippet != '' OR context != '' OR raw_text != '')`,
		// A channel-level item lists folded messages in mentions (ts deduped,
		// so at most one entry matches).
		`UPDATE inbox_items SET mentions = json_set(mentions, '$[' || (
		     SELECT key FROM json_each(inbox_items.mentions) WHERE json_extract(value, '$.ts') = ?2) || '].text', '')
		 WHERE channel_id = ?1 AND json_valid(mentions) AND EXISTS (
		     SELECT 1 FROM json_each(inbox_items.mentions)
		     WHERE json_extract(value, '$.ts') = ?2 AND json_extract(value, '$.text') != '')`,
	}
	n := 0
	for _, k := range keys {
		res, err := tx.Exec(`UPDATE messages SET is_deleted = 1, text = '', raw_json = '{}'
			WHERE channel_id = ? AND ts = ? AND is_deleted = 0`, k.ChannelID, k.TS)
		if err != nil {
			return 0, fmt.Errorf("tombstoning %s/%s: %w", k.ChannelID, k.TS, err)
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return 0, fmt.Errorf("tombstoning %s/%s: %w", k.ChannelID, k.TS, err)
		}
		if affected == 0 {
			continue
		}
		n++
		for _, q := range stmts {
			if _, err := tx.Exec(q, k.ChannelID, k.TS); err != nil {
				return 0, fmt.Errorf("clearing copies of %s/%s: %w", k.ChannelID, k.TS, err)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit slack tombstones: %w", err)
	}
	return n, nil
}

// SlackDeletionSweepDay returns the last UTC day ("YYYY-MM-DD") the Slack
// deletion sweep finished for the account; "" means it never ran.
func (db *DB) SlackDeletionSweepDay(accountID int64) (string, error) {
	var day string
	if err := db.QueryRow(`SELECT deletion_sweep_day FROM slack_accounts WHERE id = ?`, accountID).Scan(&day); err != nil {
		return "", fmt.Errorf("reading deletion sweep day of slack account %d: %w", accountID, err)
	}
	return day, nil
}

// SetSlackDeletionSweepDay stores day ("YYYY-MM-DD", UTC) as the last day the
// Slack deletion sweep finished for the account.
func (db *DB) SetSlackDeletionSweepDay(accountID int64, day string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET deletion_sweep_day = ? WHERE id = ?`, day, accountID)
	if err != nil {
		return fmt.Errorf("setting deletion sweep day of slack account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting deletion sweep day: no slack_accounts row %d", accountID)
	}
	return nil
}

// NextSlackSweepDay returns the newest UTC day holding a live plain message
// (empty subtype, not deleted) of the account with ts_unix < before; ok is
// false when there is none.
func (db *DB) NextSlackSweepDay(accountID int64, before float64) (day string, ok bool, err error) {
	prefix := strconv.FormatInt(accountID, 10)
	err = db.QueryRow(`SELECT date(ts_unix, 'unixepoch') FROM messages
		WHERE channel_id >= ? AND channel_id < ? AND subtype = '' AND is_deleted = 0 AND ts_unix < ?
		ORDER BY ts_unix DESC LIMIT 1`, prefix+":", prefix+";", before).Scan(&day)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("finding next sweep day of slack account %d: %w", accountID, err)
	}
	return day, true, nil
}
