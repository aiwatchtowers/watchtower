package db

import (
	"database/sql"
	"fmt"
)

// normalizeLegacyChatTables brings chat tables the Desktop app created before
// migration 00076 up to the one shape 00076 expects, and runs BEFORE goose.
//
// The Swift side used to create chat_conversations/chat_messages lazily (GRDB
// ensureTable) and add context_type/context_id/turn_id with guarded ALTERs, so
// an install may hold the tables with or without those columns. A SQL
// migration cannot say "add the column if missing", hence this Go step.
// Idempotent: a no-op on a fresh install (no tables yet — 00076 creates them)
// and on every open after adoption (columns present).
func normalizeLegacyChatTables(db *sql.DB) error {
	adds := []struct{ table, column, ddl string }{
		{"chat_conversations", "context_type", "ALTER TABLE chat_conversations ADD COLUMN context_type TEXT"},
		{"chat_conversations", "context_id", "ALTER TABLE chat_conversations ADD COLUMN context_id TEXT"},
		{"chat_messages", "turn_id", "ALTER TABLE chat_messages ADD COLUMN turn_id TEXT NOT NULL DEFAULT ''"},
	}
	for _, a := range adds {
		cols, err := chatTableColumns(db, a.table)
		if err != nil {
			return err
		}
		if cols == nil || cols[a.column] {
			continue // table absent (00076 creates it) or column already there
		}
		if _, err := db.Exec(a.ddl); err != nil {
			return fmt.Errorf("adding %s.%s: %w", a.table, a.column, err)
		}
	}
	return nil
}

// chatTableColumns returns the column set of table, or nil when the table does
// not exist. table is always one of the constant names above, never input.
func chatTableColumns(db *sql.DB, table string) (map[string]bool, error) {
	rows, err := db.Query(fmt.Sprintf("SELECT name FROM pragma_table_info('%s')", table))
	if err != nil {
		return nil, fmt.Errorf("reading %s columns: %w", table, err)
	}
	defer rows.Close()
	var cols map[string]bool
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("scanning %s column: %w", table, err)
		}
		if cols == nil {
			cols = map[string]bool{}
		}
		cols[name] = true
	}
	return cols, rows.Err()
}
