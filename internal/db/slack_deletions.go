package db

import (
	"fmt"
	"strconv"
)

// SlackMessageKey names one stored Slack message: the namespaced channel id
// ("<account>:<raw id>") and the Slack ts.
type SlackMessageKey struct{ ChannelID, TS string }

// LiveSlackMessageKeys lists the account's live, plain messages (empty subtype
// and not deleted) with from <= ts_unix < to. Rows with a subtype are left
// out because search.messages never returns join/leave events.
func (db *DB) LiveSlackMessageKeys(accountID int64, from, to float64) ([]SlackMessageKey, error) {
	prefix := strconv.FormatInt(accountID, 10)
	rows, err := db.Query(`SELECT channel_id, ts FROM messages
		WHERE channel_id >= ? AND channel_id < ? AND subtype = '' AND is_deleted = 0
		  AND ts_unix >= ? AND ts_unix < ?`, prefix+":", prefix+";", from, to)
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
// that is already a tombstone, or not stored, is skipped. It returns how many
// rows were tombstoned.
func (db *DB) TombstoneSlackMessages(keys []SlackMessageKey) (int, error) {
	if len(keys) == 0 {
		return 0, nil
	}
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
