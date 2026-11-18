package db

import (
	"database/sql"
	"fmt"
	"strconv"
	"time"
)

// Watchman backtest storage helpers (Task 8): the leak-free reads a backtest
// builds its context from, and the writes of a running backtest.

// WatchmanBacktestCandidates returns the newest limit precedents of a
// category the backtest may hide, newest first: every precedent except a
// review round's outcome (its situation names the round's comments, which
// gives the answer away) and the one-answer items — an undone hunk (only
// ever "undid hunk") and every git item (a merge is only ever "merged", a
// rewrite of the agent's commit only ever "rewrote").
func (db *DB) WatchmanBacktestCandidates(workbenchID int64, category string, limit int) ([]WatchmanPrecedent, error) {
	rows, err := db.Query(`SELECT `+watchmanPrecedentCols+`
		FROM watchman_precedents WHERE workbench_id = ? AND category = ?
			AND source <> 'git'
			AND COALESCE(is_decision, 1) = 1 AND COALESCE(parked, 0) = 0
			AND NOT (source = 'review' AND (source_key LIKE ? OR source_key LIKE ?))
		ORDER BY decided_at DESC, id DESC LIMIT ?`,
		workbenchID, category, WatchmanReviewRound+":%", WatchmanReviewRevert+":%", limit)
	if err != nil {
		return nil, fmt.Errorf("reading watchman backtest candidates %d/%s: %w", workbenchID, category, err)
	}
	return scanWatchmanPrecedents(rows)
}

// WatchmanPrecedentsBefore returns the newest limit precedents of a category
// in a workbench decided strictly before `before`, newest first.
func (db *DB) WatchmanPrecedentsBefore(workbenchID int64, category string, before time.Time, limit int) ([]WatchmanPrecedent, error) {
	rows, err := db.Query(`SELECT `+watchmanPrecedentCols+`
		FROM watchman_precedents WHERE workbench_id = ? AND category = ? AND decided_at < ?
		ORDER BY decided_at DESC, id DESC LIMIT ?`, workbenchID, category, wmTime(before), limit)
	if err != nil {
		return nil, fmt.Errorf("reading watchman precedents %d/%s before a cutoff: %w", workbenchID, category, err)
	}
	return scanWatchmanPrecedents(rows)
}

func scanWatchmanPrecedents(rows *sql.Rows) ([]WatchmanPrecedent, error) {
	defer rows.Close()
	var out []WatchmanPrecedent
	for rows.Next() {
		var p WatchmanPrecedent
		var decided string
		var isDec, parked sql.NullBool
		if err := rows.Scan(&p.ID, &p.WorkbenchID, &p.Source, &p.SourceKey, &p.Category, &p.Situation, &p.Choice, &p.OwnerWords, &decided, &p.Weight, &isDec, &parked); err != nil {
			return nil, fmt.Errorf("scanning watchman precedent: %w", err)
		}
		p.IsDecision, p.Parked = wmNullBool(isDec), wmNullBool(parked)
		p.DecidedAt, _ = time.Parse(time.RFC3339, decided)
		out = append(out, p)
	}
	return out, rows.Err()
}

// OwnerInstructionsBefore returns the global instructions whose row was last
// updated strictly before `before`; a row updated later reads "" (its older
// text is not kept, so it is left out rather than leak a newer one).
func (db *DB) OwnerInstructionsBefore(before time.Time) (OwnerInstructions, error) {
	rows, err := db.Query(`SELECT scope, body FROM owner_instructions WHERE updated_at < ?`, wmTime(before))
	if err != nil {
		return OwnerInstructions{}, fmt.Errorf("reading owner instructions before a cutoff: %w", err)
	}
	defer rows.Close()
	var out OwnerInstructions
	for rows.Next() {
		var scope, body string
		if err := rows.Scan(&scope, &body); err != nil {
			return OwnerInstructions{}, fmt.Errorf("scanning owner instructions: %w", err)
		}
		switch InstructionField(scope) {
		case InstructionSession:
			out.Session = body
		case InstructionProcedure:
			out.Procedure = body
		case InstructionChat:
			out.Chat = body
		}
	}
	if err := rows.Err(); err != nil {
		return OwnerInstructions{}, fmt.Errorf("reading owner instructions before a cutoff: %w", err)
	}
	return out, nil
}

// AddWatchmanBacktestRow stores one finished category's result of a backtest.
func (db *DB) AddWatchmanBacktestRow(backtestID int64, r WatchmanBacktestRow) error {
	return insertWatchmanBacktestRow(db, backtestID, r)
}

// insertWatchmanBacktestRow writes one row through e (the database or a
// transaction).
func insertWatchmanBacktestRow(e execer, backtestID int64, r WatchmanBacktestRow) error {
	if _, err := e.Exec(`INSERT INTO watchman_backtest_rows (backtest_id, category, total, agree, acceptable, bad, wrong_high,
		cost_usd, baseline, rec_baseline, status, handed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		backtestID, r.Category, r.Total, r.Agree, r.Acceptable, r.Bad, r.WrongHigh, r.CostUSD, r.Baseline, r.RecBaseline, r.Status, r.Handed); err != nil {
		return fmt.Errorf("saving watchman backtest %d row %s: %w", backtestID, r.Category, err)
	}
	return nil
}

// FinishWatchmanBacktest closes a running backtest as done (with its verdict)
// or failed (with its error). A row no longer running is left as it is.
func (db *DB) FinishWatchmanBacktest(id int64, status, verdict, errText string, costUSD float64, at time.Time) error {
	if _, err := db.Exec(`UPDATE watchman_backtests SET status = ?, verdict = ?, error = ?, cost_usd = ?, finished_at = ?
		WHERE id = ? AND status = 'running'`, status, verdict, errText, costUSD, wmTime(at), id); err != nil {
		return fmt.Errorf("finishing watchman backtest %d: %w", id, err)
	}
	return nil
}

// WatchmanBacktestByID returns backtest id of the workbench with its rows
// (nil when there is no such row).
func (db *DB) WatchmanBacktestByID(workbenchID, id int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	return db.watchmanBacktestWhere("AND id = "+strconv.FormatInt(id, 10), workbenchID)
}
