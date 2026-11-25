package db

import (
	"database/sql"
	"fmt"
)

// The queued-draft writers, ported from the Desktop's QueuedDraftQueries
// (chat_queued_drafts, migration 00157): an embedded chat's queued owner
// message, kept so a quit before its turn starts brings it back (CHAT-01).
// Pinned with the Swift writers by internal/chatstore/testdata/chat_writes.json.
//
// A "Not clear?" chat's key follows its conversation (askExplainDraftKeyTx,
// ask #1849): a save for a deleted one writes nothing, and a save or clear
// under the key a workbench merge replaced lands on the current key. Every
// other surface's key is used as is.

// SaveQueuedDraftTx stores (or replaces) a surface's queued text; at is Unix
// seconds.
func SaveQueuedDraftTx(tx *sql.Tx, key, text string, at float64) error {
	key, keep, err := askExplainDraftKeyTx(tx, key)
	if err != nil || !keep {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO chat_queued_drafts (surface_key, text, at) VALUES (?, ?, ?)
ON CONFLICT(surface_key) DO UPDATE SET text = excluded.text, at = excluded.at`, key, text, at); err != nil {
		return fmt.Errorf("save queued draft: %w", err)
	}
	return nil
}

// ClearQueuedDraftTx removes a surface's queued text; a missing row is fine.
func ClearQueuedDraftTx(tx *sql.Tx, key string) error {
	current, _, err := askExplainDraftKeyTx(tx, key)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM chat_queued_drafts WHERE surface_key IN (?, ?)`, key, current); err != nil {
		return fmt.Errorf("clear queued draft: %w", err)
	}
	return nil
}
