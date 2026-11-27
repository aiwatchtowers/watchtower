package db

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// WorktreeLastSeen is the newest sighting (last_at, else first_at) of root
// in any session's worktree ledger; false when no session recorded it. A
// stored stamp that does not parse is an error, never a zero time: the
// caller (the cleanup's idleness measure) must fail closed. It is one read
// in a read-only transaction, so it never takes the write lock.
func (db *DB) WorktreeLastSeen(ctx context.Context, root string) (time.Time, bool, error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading worktree %s last sighting: %w", root, err)
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `SELECT COALESCE(last_at, first_at)
		FROM terminal_session_worktrees WHERE root = ?`, root)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("reading worktree %s last sighting: %w", root, err)
	}
	defer func() { _ = rows.Close() }()
	var newest time.Time
	found := false
	for rows.Next() {
		var stamp sql.NullString
		if err := rows.Scan(&stamp); err != nil {
			return time.Time{}, false, fmt.Errorf("reading worktree %s last sighting: %w", root, err)
		}
		at, ok := ParseAgentStateStamp(stamp.String)
		if !stamp.Valid || !ok {
			return time.Time{}, false, fmt.Errorf("worktree %s last sighting %q is not a stamp", root, stamp.String)
		}
		if !found || at.After(newest) {
			newest, found = at, true
		}
	}
	if err := rows.Err(); err != nil {
		return time.Time{}, false, fmt.Errorf("reading worktree %s last sighting: %w", root, err)
	}
	return newest, found, nil
}
