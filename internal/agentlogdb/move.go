package agentlogdb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// ErrNotMoved is a scan's refusal before MoveFromMain completed: a scan into
// an empty agent_log_files would reparse every transcript from offset 0.
var ErrNotMoved = errors.New("agent analytics: rows not moved from watchtower.db yet")

// movedKey is the agent_log_meta key MoveFromMain sets, valued with the RFC
// 3339 UTC time the copy completed.
const movedKey = "moved_from_main"

// Test seams: the rows per copy or delete transaction, the move lock's wait,
// and a hook called after each committed copy chunk ("copy <table>") and
// before each delete transaction ("delete <table>"); its error aborts the move.
var (
	moveChunk    = 5000
	moveLockWait = 2 * time.Minute
	moveHook     func(step string) error
)

// moveTable is one agent_log_* table MoveFromMain copies: cols[0] is the key
// the copy pages by; filter, when set, limits the rows read from
// watchtower.db.
type moveTable struct {
	name   string
	cols   []string
	filter string
}

// moveTables are copied in this order (events need their session) and
// deleted from watchtower.db in the reverse one.
var moveTables = []moveTable{
	{name: "agent_log_files", cols: []string{"path", "agent", "size", "mtime", "read_offset", "parser_version", "missing_at", "scanned_at"}},
	{name: "agent_log_sessions", cols: []string{"session_uuid", "agent", "project_id", "folder_path", "home_cwd",
		"terminal_session_id", "source_path", "git_branch", "model", "started_at", "ended_at", "reported_cost_usd"}},
	// An event whose session is gone (written with foreign keys off) would
	// fail agentlog.db's foreign key on every retry; no report reaches it.
	{name: "agent_log_events", cols: []string{"id", "session_uuid", "key", "kind", "ts", "uuid", "parent_uuid", "prompt_id",
		"agent_id", "is_sidechain", "name", "target", "trigger", "outcome", "error_class", "duration_ms", "skill",
		"input_tokens", "output_tokens", "cache_read_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens",
		"speed", "service_tier", "cost_usd", "price_version", "cost_estimated", "lines_added", "lines_removed",
		"src_path", "src_offset", "spawned_agent_id", "background"},
		filter: "session_uuid IN (SELECT session_uuid FROM agent_log_sessions)"},
}

// MoveLockPath is the move's flock beside the agentlog.db at path.
func MoveLockPath(path string) string { return path + ".move.lock" }

// MoveCounts is a row count per moved table.
type MoveCounts struct{ Files, Sessions, Events int64 }

// at is the count of moveTables[i].
func (c *MoveCounts) at(i int) *int64 { return [...]*int64{&c.Files, &c.Sessions, &c.Events}[i] }

// MoveResult is what one MoveFromMain call did, for its caller's log line.
type MoveResult struct {
	Copied  MoveCounts // rows inserted into agentlog.db
	Deleted MoveCounts // rows deleted from watchtower.db
	// OrphanEvents are watchtower.db events whose session was gone (written
	// with foreign keys off): deleted, never copied.
	OrphanEvents int64
	Elapsed      time.Duration
}

// String is the move's one log line; "" for a nil result.
func (r *MoveResult) String() string {
	if r == nil {
		return ""
	}
	return fmt.Sprintf("agent analytics: moved out of watchtower.db in %s: copied %d files, %d sessions, %d events; "+
		"deleted %d files, %d sessions, %d events from watchtower.db; %d orphan events dropped",
		r.Elapsed.Round(time.Millisecond), r.Copied.Files, r.Copied.Sessions, r.Copied.Events,
		r.Deleted.Files, r.Deleted.Sessions, r.Deleted.Events, r.OrphanEvents)
}

// Moved reports whether MoveFromMain completed for this agentlog.db.
func (d *DB) Moved() (bool, error) {
	var ok bool
	if err := d.QueryRow(`SELECT EXISTS (SELECT 1 FROM agent_log_meta WHERE key = ?)`, movedKey).Scan(&ok); err != nil {
		return false, fmt.Errorf("reading the move marker: %w", err)
	}
	return ok, nil
}

// MoveFromMain moves the agent_log_* rows an older release wrote into
// watchtower.db over to al, once (spec D4). Under an exclusive flock on
// lockPath (MoveLockPath; a second mover waits, then finds the marker): when
// al has no marker, it copies files, sessions and events in moveChunk-row
// INSERT OR IGNORE transactions, reading watchtower.db only in read-only
// transactions, and sets the marker with the last chunk; then it deletes
// whatever rows watchtower.db's tables still hold, moveChunk rows per write
// transaction — the only analytics write to watchtower.db. The tables stay,
// empty: an older binary on the same data directory still declares them.
// Interrupted anywhere, the next call resumes (keys are unique; a marked
// move skips straight to the delete). The result is nil when it moved
// nothing (every count zero), so a fresh install logs nothing.
func MoveFromMain(ctx context.Context, main *db.DB, al *DB, lockPath string) (*MoveResult, error) {
	start := time.Now()
	lockCtx, cancel := context.WithTimeout(ctx, moveLockWait)
	defer cancel()
	unlock, err := fsutil.LockFile(lockCtx, lockPath)
	if err != nil {
		return nil, fmt.Errorf("taking the move lock: %w", err)
	}
	defer unlock()
	has, err := main.HasTable(moveTables[0].name)
	if err != nil {
		return nil, err
	}
	moved, err := al.Moved()
	if err != nil {
		return nil, err
	}
	res := &MoveResult{}
	switch {
	case !moved && !has:
		if err := al.withTx(setMoved); err != nil {
			return nil, fmt.Errorf("setting the move marker: %w", err)
		}
	case !moved:
		for i, t := range moveTables {
			if err := copyTable(ctx, main, al, t, i == len(moveTables)-1, res.Copied.at(i)); err != nil {
				return nil, fmt.Errorf("copying %s: %w", t.name, err)
			}
		}
	}
	if has {
		if err := main.QueryRowContext(ctx, `SELECT COUNT(*) FROM agent_log_events
			WHERE session_uuid NOT IN (SELECT session_uuid FROM agent_log_sessions)`).Scan(&res.OrphanEvents); err != nil {
			return nil, fmt.Errorf("counting orphan events: %w", err)
		}
		for i := len(moveTables) - 1; i >= 0; i-- {
			if err := deleteRows(ctx, main, moveTables[i].name, res.Deleted.at(i)); err != nil {
				return nil, fmt.Errorf("deleting %s from watchtower.db: %w", moveTables[i].name, err)
			}
		}
	}
	if res.Copied == (MoveCounts{}) && res.Deleted == (MoveCounts{}) && res.OrphanEvents == 0 {
		return nil, nil
	}
	res.Elapsed = time.Since(start)
	return res, nil
}

// setMoved writes the move marker.
func setMoved(tx *sql.Tx) error {
	_, err := tx.Exec(`INSERT OR REPLACE INTO agent_log_meta (key, value) VALUES (?, ?)`,
		movedKey, time.Now().UTC().Format(time.RFC3339))
	return err
}

// copyTable copies t from main into al by key order, one write transaction
// per chunk, adding the rows inserted to copied; when last, the final chunk
// (possibly empty) also sets the marker.
func copyTable(ctx context.Context, main *db.DB, al *DB, t moveTable, last bool, copied *int64) error {
	cols := strings.Join(t.cols, ", ")
	//nolint:gosec // G202: table and column names are moveTables' constants; every value is a bound arg.
	insert := `INSERT OR IGNORE INTO ` + t.name + ` (` + cols + `) VALUES (?` + strings.Repeat(", ?", len(t.cols)-1) + `)`
	var after any
	for {
		rows, err := readChunk(ctx, main, t, after)
		if err != nil {
			return err
		}
		done := len(rows) < moveChunk
		var n int64
		err = al.withTx(func(tx *sql.Tx) error {
			stmt, err := tx.Prepare(insert)
			if err != nil {
				return err
			}
			defer stmt.Close()
			for _, r := range rows {
				res, err := stmt.Exec(r...)
				if err != nil {
					return err
				}
				k, err := res.RowsAffected()
				if err != nil {
					return err
				}
				n += k
			}
			if done && last {
				return setMoved(tx)
			}
			return nil
		})
		if err != nil {
			return err
		}
		*copied += n
		if err := hook("copy " + t.name); err != nil {
			return err
		}
		if done {
			return nil
		}
		after = rows[len(rows)-1][0]
	}
}

// readChunk reads up to moveChunk rows of t from main with a key above after
// (nil: from the start), in a read-only transaction.
func readChunk(ctx context.Context, main *db.DB, t moveTable, after any) ([][]any, error) {
	var where []string
	var args []any
	if after != nil {
		where = append(where, t.cols[0]+" > ?")
		args = append(args, after)
	}
	if t.filter != "" {
		where = append(where, t.filter)
	}
	//nolint:gosec // G202: table, column and filter are moveTables' constants; every value is a bound arg.
	q := `SELECT ` + strings.Join(t.cols, ", ") + ` FROM ` + t.name
	if len(where) > 0 {
		q += ` WHERE ` + strings.Join(where, " AND ")
	}
	q += ` ORDER BY ` + t.cols[0] + ` LIMIT ?`
	args = append(args, moveChunk)

	tx, err := main.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, fmt.Errorf("beginning read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]any
	for rows.Next() {
		r := make([]any, len(t.cols))
		ptrs := make([]any, len(r))
		for i := range r {
			ptrs[i] = &r[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// deleteRows empties table in main, moveChunk rows per write transaction,
// adding the rows deleted to deleted.
func deleteRows(ctx context.Context, main *db.DB, table string, deleted *int64) error {
	for {
		var left bool
		if err := main.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM `+table+`)`).Scan(&left); err != nil {
			return err
		}
		if !left {
			return nil
		}
		if err := hook("delete " + table); err != nil {
			return err
		}
		res, err := main.ExecContext(ctx, `DELETE FROM `+table+` WHERE rowid IN (SELECT rowid FROM `+table+` ORDER BY rowid LIMIT ?)`, moveChunk)
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		*deleted += n
	}
}

func hook(step string) error {
	if moveHook == nil {
		return nil
	}
	return moveHook(step)
}
