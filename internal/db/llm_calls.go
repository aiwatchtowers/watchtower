package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strings"
	"time"

	"watchtower/internal/llmusage"
)

// LLM usage ledger (migration 00163, spec
// docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md): the daemon
// writes its own calls through LLMCallSink and imports every other process's
// spool with ImportLLMSpool.

const insertLLMCallSQL = `INSERT OR IGNORE INTO llm_calls (
	call_id, at, surface, purpose, process, provider, model,
	input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens, output_tokens,
	usage_estimated, reported_cost_usd, est_cost_usd, duration_ms, ok,
	automation_id, automation_run_id)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

func llmCallArgs(c llmusage.Call) []any {
	return []any{
		c.CallID, c.At, c.Surface, c.Purpose, c.Process, c.Provider, c.Model,
		c.Input, c.CacheRead, c.CacheWrite5m, c.CacheWrite1h, c.Output,
		boolToInt(c.Estimated), c.ReportedCostUSD, c.EstCostUSD, c.DurationMS, boolToInt(c.OK),
		c.AutomationID, c.AutomationRunID,
	}
}

// InsertLLMCalls stores calls in one transaction; a call_id already present
// (or a row violating a constraint) is skipped.
func (db *DB) InsertLLMCalls(calls []llmusage.Call) error {
	if len(calls) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin llm_calls insert: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(insertLLMCallSQL)
	if err != nil {
		return fmt.Errorf("prepare llm_calls insert: %w", err)
	}
	defer stmt.Close()
	for _, c := range calls {
		if _, err := stmt.Exec(llmCallArgs(c)...); err != nil {
			return fmt.Errorf("insert llm_calls: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit llm_calls insert: %w", err)
	}
	return nil
}

// LLMCallSink is the daemon's llmusage.Sink: one autocommit insert per call.
type LLMCallSink struct{ DB *DB }

// Write implements llmusage.Sink.
func (s LLMCallSink) Write(c llmusage.Call) error {
	if _, err := s.DB.Exec(insertLLMCallSQL, llmCallArgs(c)...); err != nil {
		return fmt.Errorf("insert llm_calls: %w", err)
	}
	return nil
}

// validLLMSurface mirrors the llm_calls.surface CHECK.
func validLLMSurface(s string) bool {
	return s == "watchtower" || s == "chat" || s == "workbench"
}

// ImportLLMSpool moves the spool at path into llm_calls and returns the
// number of calls read. Under the spool lock it only claims a file: a
// leftover path+".importing" (an earlier import that did not finish) or else
// path renamed to it; parsing and the insert run after the lock is released.
// Malformed lines and lines the table would refuse are skipped and logged as
// a count. The claimed file is removed once its calls are stored, so a crash
// in between re-imports it, and call_id UNIQUE keeps that idempotent.
func (db *DB) ImportLLMSpool(path string) (int, error) {
	claimed, err := claimLLMSpool(path)
	if err != nil || claimed == "" {
		return 0, err
	}
	calls, skipped, err := llmusage.ParseSpoolFile(claimed)
	if err != nil {
		return 0, err
	}
	valid := calls[:0]
	for _, c := range calls {
		if c.At == "" || !validLLMSurface(c.Surface) {
			skipped++
			continue
		}
		valid = append(valid, c)
	}
	if skipped > 0 {
		log.Printf("llmusage: spool import skipped %d malformed lines", skipped)
	}
	if err := db.InsertLLMCalls(valid); err != nil {
		return 0, err
	}
	if err := os.Remove(claimed); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return len(valid), fmt.Errorf("removing imported spool: %w", err)
	}
	return len(valid), nil
}

// claimLLMSpool returns the file to import ("" = nothing to do), holding the
// spool lock only for the existence check and the rename.
func claimLLMSpool(path string) (string, error) {
	importing := path + llmusage.ImportingSuffix
	unlock, err := llmusage.LockSpool(path)
	if err != nil {
		return "", err
	}
	defer unlock()
	if _, err := os.Lstat(importing); err == nil {
		return importing, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("checking importing spool: %w", err)
	}
	if err := os.Rename(path, importing); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("claiming spool: %w", err)
	}
	return importing, nil
}

// PruneLLMCalls deletes the calls that finished before before.
func (db *DB) PruneLLMCalls(before time.Time) (int64, error) {
	res, err := db.Exec(`DELETE FROM llm_calls WHERE at < ?`, before.UTC().Format(time.RFC3339))
	if err != nil {
		return 0, fmt.Errorf("prune llm_calls: %w", err)
	}
	return res.RowsAffected()
}

// LLMUsageGroup is one aggregated ledger row: the calls of one surface,
// purpose, model and automation; untagged calls (empty purpose) are also
// split by process, so each command that made them gets its own row
// (Process is empty for tagged rows).
type LLMUsageGroup struct {
	Surface, Purpose, Process, Model string
	AutomationID                     *int64
	AutomationName, AutomationOrigin string // '' when no automation or the row is gone
	Calls, Runs, Errors, Estimated   int64
	NoPrice                          int64 // calls with neither a reported nor an estimated cost
	Input, CacheRead, CacheWrite     int64 // CacheWrite = 5m + 1h
	Output                           int64
	ReportedUSD, EstUSD              float64 // sums of the non-NULL costs
	// CostUSD sums each call's cost: its reported cost when non-zero, else
	// its estimate, else nothing (LLMCallCost).
	CostUSD float64
	// EstCostCalls counts the calls whose cost is their estimate (reported
	// NULL or 0, estimate present).
	EstCostCalls int64
}

// LLMCallCost is one call's cost in a usage total: the reported cost when
// non-zero, else the estimate (estimated = true), else the reported zero;
// known = false when the call has neither. LLMUsageRows applies the same
// rule in SQL.
func LLMCallCost(reported, est *float64) (usd float64, estimated, known bool) {
	switch {
	case reported != nil && *reported != 0:
		return *reported, false, true
	case est != nil:
		return *est, true, true
	case reported != nil:
		return 0, false, true
	}
	return 0, false, false
}

// llmQueryer is the read transaction ReadLLMUsage runs the ledger reads on.
type llmQueryer interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

// LLMUsageSnapshot is everything `usage llm` reads from llm_calls, taken
// in one read transaction so the parts agree with each other.
type LLMUsageSnapshot struct {
	Groups []LLMUsageGroup
	// Runs is, per automation, the distinct run ids (llmAutomationRuns).
	Runs map[int64][]int64
	// Since is the earliest call's time; SinceFound is false while empty.
	Since      time.Time
	SinceFound bool
	// Present marks which of the asked call ids are already stored.
	Present map[string]bool
}

// ReadLLMUsage reads the groups and runs since since, the ledger start and
// which of ids are stored, in one read-only transaction (it never blocks a
// writer, and an import committing meanwhile is seen by none of the parts).
func (db *DB) ReadLLMUsage(ctx context.Context, since time.Time, ids []string) (LLMUsageSnapshot, error) {
	var s LLMUsageSnapshot
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return s, fmt.Errorf("begin llm usage read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if s.Groups, err = llmUsageRows(tx, since); err != nil {
		return s, err
	}
	if s.Runs, err = llmAutomationRuns(tx, since); err != nil {
		return s, err
	}
	if s.Since, s.SinceFound, err = llmLedgerSince(tx); err != nil {
		return s, err
	}
	if s.Present, err = llmCallIDsPresent(tx, ids); err != nil {
		return s, err
	}
	return s, nil
}

// llmUsageRows aggregates the calls that finished at or after since.
func llmUsageRows(q llmQueryer, since time.Time) ([]LLMUsageGroup, error) {
	rows, err := q.Query(`
		SELECT l.surface, l.purpose,
		       CASE WHEN l.purpose = '' THEN l.process ELSE '' END AS proc_key,
		       l.model, l.automation_id,
		       COALESCE(MAX(NULLIF(a.name, '')), MAX(a.slug), ''), COALESCE(MAX(a.origin), ''),
		       COUNT(*), COUNT(DISTINCT l.automation_run_id),
		       SUM(l.ok = 0), SUM(l.usage_estimated != 0),
		       SUM(l.reported_cost_usd IS NULL AND l.est_cost_usd IS NULL),
		       SUM(l.input_tokens), SUM(l.cache_read_tokens),
		       SUM(l.cache_write_5m_tokens + l.cache_write_1h_tokens), SUM(l.output_tokens),
		       COALESCE(SUM(l.reported_cost_usd), 0), COALESCE(SUM(l.est_cost_usd), 0),
		       SUM(COALESCE(NULLIF(l.reported_cost_usd, 0), l.est_cost_usd, 0)),
		       SUM(COALESCE(l.reported_cost_usd, 0) = 0 AND l.est_cost_usd IS NOT NULL)
		FROM llm_calls l
		LEFT JOIN automations a ON a.id = l.automation_id
		WHERE l.at >= ?
		GROUP BY l.surface, l.purpose, proc_key, l.model, l.automation_id
		ORDER BY l.surface, l.purpose, proc_key, l.model, l.automation_id`,
		since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("query llm usage: %w", err)
	}
	defer rows.Close()
	var out []LLMUsageGroup
	for rows.Next() {
		var g LLMUsageGroup
		var aid sql.NullInt64
		if err := rows.Scan(&g.Surface, &g.Purpose, &g.Process, &g.Model, &aid,
			&g.AutomationName, &g.AutomationOrigin,
			&g.Calls, &g.Runs, &g.Errors, &g.Estimated, &g.NoPrice,
			&g.Input, &g.CacheRead, &g.CacheWrite, &g.Output,
			&g.ReportedUSD, &g.EstUSD, &g.CostUSD, &g.EstCostCalls); err != nil {
			return nil, fmt.Errorf("scan llm usage: %w", err)
		}
		if aid.Valid {
			v := aid.Int64
			g.AutomationID = &v
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// llmAutomationRuns returns, per automation, the distinct run ids of its
// calls that finished at or after since (a run's calls can span several
// LLMUsageGroup rows, so their Runs do not add up).
func llmAutomationRuns(q llmQueryer, since time.Time) (map[int64][]int64, error) {
	rows, err := q.Query(`SELECT DISTINCT automation_id, automation_run_id FROM llm_calls
		WHERE at >= ? AND automation_id IS NOT NULL AND automation_run_id IS NOT NULL`,
		since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("query llm automation runs: %w", err)
	}
	defer rows.Close()
	out := map[int64][]int64{}
	for rows.Next() {
		var aid, rid int64
		if err := rows.Scan(&aid, &rid); err != nil {
			return nil, fmt.Errorf("scan llm automation runs: %w", err)
		}
		out[aid] = append(out[aid], rid)
	}
	return out, rows.Err()
}

// llmCallIDsPresent returns which of ids are already in llm_calls.
func llmCallIDsPresent(q llmQueryer, ids []string) (map[string]bool, error) {
	out := map[string]bool{}
	const chunk = 500
	for start := 0; start < len(ids); start += chunk {
		part := ids[start:min(start+chunk, len(ids))]
		if err := llmCallIDsIn(q, part, out); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// llmCallIDsIn marks in out which of ids are in llm_calls.
func llmCallIDsIn(q llmQueryer, ids []string, out map[string]bool) error {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	rows, err := q.Query(`SELECT call_id FROM llm_calls WHERE call_id IN (?`+
		strings.Repeat(",?", len(ids)-1)+`)`, args...)
	if err != nil {
		return fmt.Errorf("query llm call ids: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return fmt.Errorf("scan llm call ids: %w", err)
		}
		out[id] = true
	}
	return rows.Err()
}

// llmLedgerSince returns the earliest recorded call's time; false when the
// ledger is empty.
func llmLedgerSince(q llmQueryer) (time.Time, bool, error) {
	var at sql.NullString
	if err := q.QueryRow(`SELECT MIN(at) FROM llm_calls`).Scan(&at); err != nil {
		return time.Time{}, false, fmt.Errorf("query llm ledger start: %w", err)
	}
	if !at.Valid {
		return time.Time{}, false, nil
	}
	t, err := time.Parse(time.RFC3339, at.String)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse llm ledger start: %w", err)
	}
	return t, true, nil
}
