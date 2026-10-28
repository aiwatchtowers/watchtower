package db

import (
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
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
}

// LLMUsageRows aggregates the calls that finished at or after since.
func (db *DB) LLMUsageRows(since time.Time) ([]LLMUsageGroup, error) {
	rows, err := db.Query(`
		SELECT l.surface, l.purpose,
		       CASE WHEN l.purpose = '' THEN l.process ELSE '' END AS proc_key,
		       l.model, l.automation_id,
		       COALESCE(MAX(NULLIF(a.name, '')), MAX(a.slug), ''), COALESCE(MAX(a.origin), ''),
		       COUNT(*), COUNT(DISTINCT l.automation_run_id),
		       SUM(l.ok = 0), SUM(l.usage_estimated != 0),
		       SUM(l.reported_cost_usd IS NULL AND l.est_cost_usd IS NULL),
		       SUM(l.input_tokens), SUM(l.cache_read_tokens),
		       SUM(l.cache_write_5m_tokens + l.cache_write_1h_tokens), SUM(l.output_tokens),
		       COALESCE(SUM(l.reported_cost_usd), 0), COALESCE(SUM(l.est_cost_usd), 0)
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
			&g.ReportedUSD, &g.EstUSD); err != nil {
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

// LLMLedgerSince returns the earliest recorded call's time; false when the
// ledger is empty.
func (db *DB) LLMLedgerSince() (time.Time, bool, error) {
	var at sql.NullString
	if err := db.QueryRow(`SELECT MIN(at) FROM llm_calls`).Scan(&at); err != nil {
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
