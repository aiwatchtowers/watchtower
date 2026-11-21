package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// Watchman precedent flags (migration 00201, spec §9.1 Store): the learner's
// relabel pass is the only writer of is_decision / parked / flags_at after a
// row is stored.

// watchmanPrecedentCols is the column list scanWatchmanPrecedents reads.
const watchmanPrecedentCols = `id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight, is_decision, parked`

// WatchmanPrecedentFlags is one row's relabel result; a nil flag stays NULL.
type WatchmanPrecedentFlags struct {
	ID                 int64
	IsDecision, Parked *bool
}

// wmFlag maps a tri-state flag to a SQL value (nil → NULL).
func wmFlag(b *bool) any {
	if b == nil {
		return nil
	}
	if *b {
		return 1
	}
	return 0
}

func wmNullBool(n sql.NullBool) *bool {
	if !n.Valid {
		return nil
	}
	v := n.Bool
	return &v
}

// WatchmanUnflagged returns the newest limit precedents of the given sources
// the relabel pass has not tried yet (flags_at IS NULL), newest first.
func (db *DB) WatchmanUnflagged(workbenchID int64, sources []string, limit int) ([]WatchmanPrecedent, error) {
	if len(sources) == 0 || limit <= 0 {
		return nil, nil
	}
	args := []any{workbenchID}
	for _, s := range sources {
		args = append(args, s)
	}
	args = append(args, limit)
	rows, err := db.Query(`SELECT `+watchmanPrecedentCols+` FROM watchman_precedents
		WHERE workbench_id = ? AND flags_at IS NULL AND source IN (`+strings.TrimSuffix(strings.Repeat("?,", len(sources)), ",")+`)
		ORDER BY decided_at DESC, id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading unflagged watchman precedents %d: %w", workbenchID, err)
	}
	return scanWatchmanPrecedents(rows)
}

// SetWatchmanPrecedentFlags writes both flags (a nil one stays NULL) and
// flags_at = at for each row, even when both are nil: the row counts as
// tried. The caller writes nil flags only after its one retry.
func (db *DB) SetWatchmanPrecedentFlags(tx *sql.Tx, flags []WatchmanPrecedentFlags, at time.Time) error {
	for _, f := range flags {
		if _, err := tx.Exec(`UPDATE watchman_precedents SET is_decision = ?, parked = ?, flags_at = ? WHERE id = ?`,
			wmFlag(f.IsDecision), wmFlag(f.Parked), wmTime(at), f.ID); err != nil {
			return fmt.Errorf("flagging watchman precedent %d: %w", f.ID, err)
		}
	}
	return nil
}

// MarkWatchmanFlagsTried sets flags_at = at on the given precedents of one
// source that have none yet: the labeller was asked (and retried once) but
// gave no flags, so the rows stay candidates and are not relabelled.
func (db *DB) MarkWatchmanFlagsTried(tx *sql.Tx, workbenchID int64, source string, keys []string, at time.Time) error {
	for _, k := range keys {
		if _, err := tx.Exec(`UPDATE watchman_precedents SET flags_at = ?
			WHERE workbench_id = ? AND source = ? AND source_key = ? AND flags_at IS NULL`,
			wmTime(at), workbenchID, source, k); err != nil {
			return fmt.Errorf("marking watchman precedent %s/%s tried: %w", source, k, err)
		}
	}
	return nil
}

// WatchmanLearningSQL is the one "still learning" rule as SQL on the
// watchman_workbenches row aliased a: not learned yet, or precedents the
// relabel pass has not tried (WatchmanFlagsPending > 0). The twin leases no
// question of such a workbench, the daemon's learner learns it to the end
// and the journal counts what waits for it (WatchmanWaitingForLearning; the
// Desktop's query is the same rule, testdata/watchman_waiting_learning_cases.json).
func WatchmanLearningSQL(a string) string {
	return `(` + a + `.learned_through IS NULL OR EXISTS (SELECT 1 FROM watchman_precedents p WHERE p.workbench_id = ` + a +
		`.workbench_id AND p.flags_at IS NULL AND p.source IN ('ask','turn','permission')))`
}

// WatchmanStillLearning reports whether Watchman is still learning the
// workbench (WatchmanLearningSQL); a workbench Watchman is not on for counts
// as still learning.
func (db *DB) WatchmanStillLearning(workbenchID int64) (bool, error) {
	var learning bool
	if err := db.QueryRow(`SELECT NOT EXISTS (SELECT 1 FROM watchman_workbenches w
		WHERE w.workbench_id = ? AND NOT `+WatchmanLearningSQL("w")+`)`, workbenchID).Scan(&learning); err != nil {
		return false, fmt.Errorf("reading whether watchman is learning workbench %d: %w", workbenchID, err)
	}
	return learning, nil
}

// WatchmanFlagsPending counts the workbench's ask/turn/permission precedents
// the relabel pass has not tried yet.
func (db *DB) WatchmanFlagsPending(workbenchID int64) (int, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM watchman_precedents
		WHERE workbench_id = ? AND flags_at IS NULL AND source IN ('ask','turn','permission')`, workbenchID).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting unflagged watchman precedents %d: %w", workbenchID, err)
	}
	return n, nil
}
