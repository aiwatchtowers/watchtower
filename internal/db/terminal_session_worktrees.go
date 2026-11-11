package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// MaxSessionWorktrees caps the source='cwd' terminal_session_worktrees rows
// of one session: a further new (root, branch) pair is not recorded.
const MaxSessionWorktrees = 64

// MaxSessionCommandRows caps the source='command' terminal_session_worktrees
// rows of one session (board #1716), apart from the cwd cap.
const MaxSessionCommandRows = 512

// SessionWorktree is a terminal_session_worktrees row of one session: a
// worktree root and the branch an agent of the session worked on there
// (empty = detached HEAD or unreadable), first seen at FirstAt (agent_state_at
// format). The row's last_at (board #1018), its last sighting, is read by
// HasSessionWorktree and the Desktop, not carried here. Source is "cwd" (an
// agent worked there) or "command" (parsed from an agent's git command, board
// #1716); Kind is "worktree" (a root with its branch) or "branch" (a
// branch-only row whose Root is the repository's top level).
type SessionWorktree struct {
	Root, Branch, FirstAt, Source, Kind string
}

// HasSessionWorktree reports whether session sessionID already recorded
// (root, branch) as a source='cwd' row — an agent worked there; a pair that
// so far is only a command row (board #1716) is not, and the next
// RecordSessionWorktree upgrades it; stale, whether that pair's last sighting (last_at, else
// first_at) is older than the session's run mark (agent_turns' since; never
// without a readable one), so this run has not seen it yet (board #1018);
// and whether the session is full — already at MaxSessionWorktrees cwd rows,
// so a new pair would not be recorded (never for a command row of the pair:
// its upgrade has no cap). It is one read in a read-only
// transaction, so it works on a query_only handle and never takes the write
// lock: the hook learns a pair is known in this run, or the session full,
// without one.
func (db *DB) HasSessionWorktree(ctx context.Context, sessionID int64, root, branch string) (has, stale, full bool, err error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return false, false, false, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	defer func() { _ = tx.Rollback() }()
	var n int
	var command bool
	var seen, since sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT
		(SELECT COALESCE(last_at, first_at) FROM terminal_session_worktrees
			WHERE session_id = ? AND root = ? AND branch = ? AND source = 'cwd'),
		EXISTS (SELECT 1 FROM terminal_session_worktrees
			WHERE session_id = ? AND root = ? AND branch = ? AND source = 'command'),
		(SELECT `+runStartExpr+` FROM terminal_sessions WHERE id = ?),
		(SELECT COUNT(*) FROM terminal_session_worktrees WHERE session_id = ? AND source = 'cwd')`,
		sessionID, root, branch, sessionID, root, branch, sessionID, sessionID).Scan(&seen, &command, &since, &n)
	if err != nil {
		return false, false, false, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	return seen.Valid, seen.Valid && seenBeforeRun(seen.String, since), !command && n >= MaxSessionWorktrees, nil
}

// seenBeforeRun reports whether a ledger stamp is older than the run mark
// since. Both are agent_state_at stamps, so they compare as text; a mark
// that is NULL or not in that layout has no run to be stale against — false,
// so a reused worktree is then not touched and the Desktop counts it in the
// run it was first seen in, as before board #1018.
func seenBeforeRun(seen string, since sql.NullString) bool {
	if !since.Valid {
		return false
	}
	if _, err := time.Parse(agentStateAtLayout, since.String); err != nil {
		return false
	}
	return seen < since.String
}

// TouchSessionWorktree moves the last sighting (last_at) of session
// sessionID's recorded source='cwd' (root, branch) to at (agent_state_at format) when the
// stored one (last_at, else first_at) is older; first_at never changes.
// touched is false, with no error, when there is no such cwd pair (a
// command-only pair goes through RecordSessionWorktree) or it was seen at or
// after at already. last_at only moves forward; concurrent hooks of one
// run may both write it (the later stamp wins), which costs a write, not a
// wrong value.
func (db *DB) TouchSessionWorktree(ctx context.Context, sessionID int64, root, branch, at string) (touched bool, err error) {
	res, err := db.ExecContext(ctx, `UPDATE terminal_session_worktrees SET last_at = ?
		WHERE session_id = ? AND root = ? AND branch = ? AND source = 'cwd' AND COALESCE(last_at, first_at) < ?`,
		at, sessionID, root, branch, at)
	if err != nil {
		return false, fmt.Errorf("touching terminal session %d worktree: %w", sessionID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("touching terminal session %d worktree: %w", sessionID, err)
	}
	return n > 0, nil
}

// RecordSessionWorktree records (root, branch) for session sessionID at time
// `at` (agent_state_at format) inside tx, or in its own transaction when tx is
// nil, as a source='cwd' row. A pair recorded only as a command row (board
// #1716) is upgraded in place — source becomes cwd, kind stays, last_at moves
// forward to at — with no cap check, and counts as recorded. A cwd pair
// already recorded is left as it is. recorded is false, with no error, when
// the cwd pair was already there or the session already holds
// MaxSessionWorktrees cwd rows.
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
	res, err := tx.ExecContext(ctx, `UPDATE terminal_session_worktrees SET source = 'cwd',
		last_at = CASE WHEN COALESCE(last_at, first_at) < ? THEN ? ELSE last_at END
		WHERE session_id = ? AND root = ? AND branch = ? AND source = 'command'`, at, at, sessionID, root, branch)
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	upgraded, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	if upgraded > 0 {
		return true, nil
	}
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM terminal_session_worktrees
		WHERE session_id = ? AND source = 'cwd'`, sessionID).Scan(&n); err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	if n >= MaxSessionWorktrees {
		return false, nil
	}
	res, err = tx.ExecContext(ctx, `INSERT OR IGNORE INTO terminal_session_worktrees (session_id, root, branch, first_at, last_at)
		VALUES (?, ?, ?, ?, ?)`, sessionID, root, branch, at, at)
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	added, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("recording terminal session %d worktree: %w", sessionID, err)
	}
	return added > 0, nil
}

// RecordSessionCommandRow records (root, branch) of kind ("worktree" or
// "branch") for session sessionID at time `at` (agent_state_at format) as a
// source='command' row, in one short write transaction. A pair already
// recorded, whatever its source, keeps its source and kind; only its last_at
// moves forward to at. recorded is false, with no error, when the pair was
// already there; full is true, and nothing is written, when the pair is new
// and the session already holds MaxSessionCommandRows command rows.
func (db *DB) RecordSessionCommandRow(ctx context.Context, sessionID int64, root, branch, kind, at string) (recorded, full bool, err error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return false, false, fmt.Errorf("recording terminal session %d command row: %w", sessionID, err)
	}
	defer func() { _ = tx.Rollback() }()
	var exists, n int
	if err := tx.QueryRowContext(ctx, `SELECT
		EXISTS (SELECT 1 FROM terminal_session_worktrees WHERE session_id = ? AND root = ? AND branch = ?),
		(SELECT COUNT(*) FROM terminal_session_worktrees WHERE session_id = ? AND source = 'command')`,
		sessionID, root, branch, sessionID).Scan(&exists, &n); err != nil {
		return false, false, fmt.Errorf("recording terminal session %d command row: %w", sessionID, err)
	}
	switch {
	case exists == 1:
		if _, err := tx.ExecContext(ctx, `UPDATE terminal_session_worktrees SET last_at = ?
			WHERE session_id = ? AND root = ? AND branch = ? AND COALESCE(last_at, first_at) < ?`,
			at, sessionID, root, branch, at); err != nil {
			return false, false, fmt.Errorf("recording terminal session %d command row: %w", sessionID, err)
		}
	case n >= MaxSessionCommandRows:
		return false, true, nil
	default:
		if _, err := tx.ExecContext(ctx, `INSERT INTO terminal_session_worktrees
			(session_id, root, branch, first_at, last_at, source, kind) VALUES (?, ?, ?, ?, ?, 'command', ?)`,
			sessionID, root, branch, at, at, kind); err != nil {
			return false, false, fmt.Errorf("recording terminal session %d command row: %w", sessionID, err)
		}
		recorded = true
	}
	if err := tx.Commit(); err != nil {
		return false, false, fmt.Errorf("recording terminal session %d command row: %w", sessionID, err)
	}
	return recorded, false, nil
}

// SessionWorktrees is session sessionID's recorded worktrees in first_at
// order; never nil.
func (db *DB) SessionWorktrees(ctx context.Context, sessionID int64) ([]SessionWorktree, error) {
	rows, err := db.QueryContext(ctx, `SELECT root, branch, first_at, source, kind FROM terminal_session_worktrees
		WHERE session_id = ? ORDER BY first_at, root, branch`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d worktrees: %w", sessionID, err)
	}
	defer rows.Close()
	out := []SessionWorktree{}
	for rows.Next() {
		var w SessionWorktree
		if err := rows.Scan(&w.Root, &w.Branch, &w.FirstAt, &w.Source, &w.Kind); err != nil {
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
// workbenchID recorded to those sessions' ids, ascending; never nil. Only
// kind='worktree' rows, of either source: a branch row's root is the
// repository's top level, never a worktree (board #1716). The sweep uses it
// for its owner hint, agentlog for its worktree roots.
func (db *DB) WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error) {
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT w.root, w.session_id
		FROM terminal_session_worktrees w JOIN terminal_sessions s ON s.id = w.session_id
		WHERE s.project_id = ? AND w.kind = 'worktree' ORDER BY w.root, w.session_id`, workbenchID)
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

// SessionTargetBranches is the trimmed, non-empty `branch` of every target
// session sessionID linked (terminal_session_targets, PROJ-14), each once,
// in name order; empty, never nil, when there is none.
func (db *DB) SessionTargetBranches(ctx context.Context, sessionID int64) ([]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT TRIM(t.branch) FROM terminal_session_targets st
		JOIN targets t ON t.id = st.target_id
		WHERE st.session_id = ? AND TRIM(t.branch) != '' ORDER BY 1`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d target branches: %w", sessionID, err)
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, fmt.Errorf("reading terminal session %d target branches: %w", sessionID, err)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading terminal session %d target branches: %w", sessionID, err)
	}
	return out, nil
}

// TerminalSessionActivity is one terminal_sessions row as the session
// cleanup's in-use and recent-owner catches read it. The stamps are as
// stored ("" = NULL): the caller decides what an unreadable one means.
type TerminalSessionActivity struct {
	ID           int64
	WorkbenchID  int64 // 0 = a standalone terminal
	Title        string
	AgentCwd     string // agent_cwd (board #565); "" = unknown
	AgentStateAt string // agent_state_at
	LastActiveAt string // last_active_at
	Finished     bool   // finished_at is set
}

// ListTerminalSessionActivity is every terminal session of every workbench
// and every standalone one, in id order, read in a read-only transaction.
func (db *DB) ListTerminalSessionActivity(ctx context.Context) ([]TerminalSessionActivity, error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, fmt.Errorf("reading terminal session activity: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `SELECT id, COALESCE(project_id, 0), title, COALESCE(agent_cwd, ''),
		COALESCE(agent_state_at, ''), last_active_at, finished_at IS NOT NULL
		FROM terminal_sessions ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("reading terminal session activity: %w", err)
	}
	defer rows.Close()
	out := []TerminalSessionActivity{}
	for rows.Next() {
		var a TerminalSessionActivity
		if err := rows.Scan(&a.ID, &a.WorkbenchID, &a.Title, &a.AgentCwd, &a.AgentStateAt,
			&a.LastActiveAt, &a.Finished); err != nil {
			return nil, fmt.Errorf("reading terminal session activity: %w", err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading terminal session activity: %w", err)
	}
	return out, nil
}
