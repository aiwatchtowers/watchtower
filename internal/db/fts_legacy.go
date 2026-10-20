package db

import (
	"database/sql"
	"fmt"
)

// dropEmptyMessagesSearchLegacy finishes migration 00146 when nothing is left
// to fill: the migration keeps the old messages index as messages_fts_legacy
// and marks fts_rebuild_pending unconditionally, since goose SQL cannot drop a
// table conditionally. With no indexable message (fresh install, or only
// empty or deleted rows) the new index is already complete, so the legacy
// table and both fill keys go in one transaction. migrate calls it after
// goose, under the migrate flock.
func dropEmptyMessagesSearchLegacy(q *sql.DB) error {
	var hasLegacy, hasIndexable bool
	if err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts_legacy')`).Scan(&hasLegacy); err != nil {
		return fmt.Errorf("looking up messages_fts_legacy: %w", err)
	}
	if !hasLegacy {
		return nil
	}
	if err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM messages WHERE text != '' AND is_deleted = 0)`).Scan(&hasIndexable); err != nil {
		return fmt.Errorf("checking for indexable messages: %w", err)
	}
	if hasIndexable {
		return nil
	}
	tx, err := q.Begin()
	if err != nil {
		return fmt.Errorf("beginning messages_fts_legacy cleanup: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DROP TABLE messages_fts_legacy`); err != nil {
		return fmt.Errorf("dropping messages_fts_legacy: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM db_maintenance WHERE key IN ('fts_rebuild_pending', 'fts_rebuild_cursor_messages')`); err != nil {
		return fmt.Errorf("clearing the search fill keys: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing messages_fts_legacy cleanup: %w", err)
	}
	return nil
}
