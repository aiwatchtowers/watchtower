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
	var newest sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT MAX(COALESCE(last_at, first_at))
		FROM terminal_session_worktrees WHERE root = ?`, root).Scan(&newest); err != nil {
		return time.Time{}, false, fmt.Errorf("reading worktree %s last sighting: %w", root, err)
	}
	if !newest.Valid {
		return time.Time{}, false, nil
	}
	at, ok := ParseAgentStateStamp(newest.String)
	if !ok {
		return time.Time{}, false, fmt.Errorf("worktree %s last sighting %q is not a stamp", root, newest.String)
	}
	return at, true, nil
}
