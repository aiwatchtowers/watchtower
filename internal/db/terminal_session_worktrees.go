package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// MaxSessionWorktrees caps the terminal_session_worktrees rows of one
// session: a further new (root, branch) pair is not recorded.
const MaxSessionWorktrees = 64

// SessionWorktree is a terminal_session_worktrees row of one session: a
// worktree root and the branch an agent of the session worked on there
// (empty = detached HEAD or unreadable), first seen at FirstAt (agent_state_at
// format).
type SessionWorktree struct {
	Root, Branch, FirstAt string
}

// HasSessionWorktree reports whether session sessionID already recorded
// (root, branch), and whether it is full — already at MaxSessionWorktrees
// rows, so a new pair would not be recorded. It is one read in a read-only
// transaction, so it works on a query_only handle and never takes the write
// lock: the hook learns a pair is known, or the session full, without one.
func (db *DB) HasSessionWorktree(ctx context.Context, sessionID int64, root, branch string) (has, full bool, err error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return false, false, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	defer func() { _ = tx.Rollback() }()
	var n int
	err = tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM terminal_session_worktrees
		WHERE session_id = ? AND root = ? AND branch = ?),
		(SELECT COUNT(*) FROM terminal_session_worktrees WHERE session_id = ?)`,
		sessionID, root, branch, sessionID).Scan(&has, &n)
	if err != nil {
		return false, false, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	return has, n >= MaxSessionWorktrees, nil
}

// RecordSessionWorktree records (root, branch) for session sessionID at time
// `at` (agent_state_at format) inside tx, or in its own transaction when tx is
// nil. A pair already recorded is left as it is. recorded is false, with no
// error, when the pair was already there or the session already holds
// MaxSessionWorktrees rows.
func (db *DB) RecordSessionWorktree(ctx context.Context, tx *sql.Tx, sessionID int64, root, branch, at string) (recorded bool, err error) {
	if tx != nil {
		return recordSessionWorktree(ctx, tx, sessionID, root, branch, at)
	}
	own, err := db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	defer func() { _ = own.Rollback() }()
	recorded, err = recordSessionWorktree(ctx, own, sessionID, root, branch, at)
	if err != nil {
		return false, err
	}
	if err := own.Commit(); err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	return recorded, nil
}

func recordSessionWorktree(ctx context.Context, tx *sql.Tx, sessionID int64, root, branch, at string) (bool, error) {
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM terminal_session_worktrees WHERE session_id = ?`,
		sessionID).Scan(&n); err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	if n >= MaxSessionWorktrees {
		return false, nil
	}
	res, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO terminal_session_worktrees (session_id, root, branch, first_at)
		VALUES (?, ?, ?, ?)`, sessionID, root, branch, at)
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	added, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	return added > 0, nil
}

// SessionWorktrees is session sessionID's recorded worktrees in first_at
// order; never nil.
func (db *DB) SessionWorktrees(ctx context.Context, sessionID int64) ([]SessionWorktree, error) {
	rows, err := db.QueryContext(ctx, `SELECT root, branch, first_at FROM terminal_session_worktrees
		WHERE session_id = ? ORDER BY first_at, root, branch`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	defer rows.Close()
	out := []SessionWorktree{}
	for rows.Next() {
		var w SessionWorktree
		if err := rows.Scan(&w.Root, &w.Branch, &w.FirstAt); err != nil {
			return nil, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
		}
		out = append(out, w)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	return out, nil
}

// WorkbenchSessionWorktrees maps each worktree root any session of workbench
// workbenchID recorded to those sessions' ids, ascending; never nil. The
// sweep uses it for its owner hint.
func (db *DB) WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error) {
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT w.root, w.session_id
		FROM terminal_session_worktrees w JOIN terminal_sessions s ON s.id = w.session_id
		WHERE s.project_id = ? ORDER BY w.root, w.session_id`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d session worktrees: %w", workbenchID, err)
	}
	defer rows.Close()
	out := map[string][]int64{}
	for rows.Next() {
		var root string
		var id int64
		if err := rows.Scan(&root, &id); err != nil {
			return nil, fmt.Errorf("reading workbench %d session worktrees: %w", workbenchID, err)
		}
		out[root] = append(out[root], id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading workbench %d session worktrees: %w", workbenchID, err)
	}
	return out, nil
}

// SaveCleanupResult stores the JSON of session sessionID's last cleanup
// apply and its time at (agent_state_at format). Only that row changes;
// ErrTerminalSessionNotFound when there is none.
func (db *DB) SaveCleanupResult(ctx context.Context, sessionID int64, resultJSON, at string) error {
	res, err := db.ExecContext(ctx, `UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?`,
		resultJSON, at, sessionID)
	if err != nil {
		return fmt.Errorf("saving terminal session %d cleanup result: %w", sessionID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("saving terminal session %d cleanup result: %w", sessionID, err)
	}
	if n == 0 {
		return fmt.Errorf("saving terminal session %d cleanup result: %w", sessionID, ErrTerminalSessionNotFound)
	}
	return nil
}

// TerminalSessionStart is session sessionID's created_at.
// ErrTerminalSessionNotFound when there is no such row; a created_at that
// does not parse is an error, never a zero time (the cleanup's ownership
// rule compares against it, and a zero start would make everything young).
func (db *DB) TerminalSessionStart(ctx context.Context, sessionID int64) (time.Time, error) {
	var raw string
	err := db.QueryRowContext(ctx, `SELECT created_at FROM terminal_sessions WHERE id = ?`, sessionID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, fmt.Errorf("reading terminal session %d start: %w", sessionID, ErrTerminalSessionNotFound)
	}
	if err != nil {
		return time.Time{}, fmt.Errorf("reading terminal session %d start: %w", sessionID, err)
	}
	at, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("reading terminal session %d start: created_at %q: %w", sessionID, raw, err)
	}
	return at, nil
}
