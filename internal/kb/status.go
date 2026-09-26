package kb

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"watchtower/internal/db"
)

// staleAfter is how old the newest source update may be before search
// results carry an "index last updated" note.
const staleAfter = 24 * time.Hour

// SourceStatus is one source's index state.
type SourceStatus struct {
	Source           string  `json:"source"`
	Docs             int     `json:"docs"`
	Chunks           int     `json:"chunks"`
	Cursor           string  `json:"cursor"`
	Progress         float64 `json:"progress"` // 0..1; below 1 only while a backfill is partial
	LastReconciledAt string  `json:"last_reconciled_at"`
	UpdatedAt        string  `json:"updated_at"`
}

// Status reports every source's index state, one row per SourceNames() entry.
func Status(ctx context.Context, d *db.DB) ([]SourceStatus, error) {
	var out []SourceStatus
	for _, src := range allSources() {
		st, err := sourceStatus(ctx, d, src)
		if err != nil {
			return nil, err
		}
		out = append(out, st)
	}
	return out, nil
}

func sourceStatus(ctx context.Context, d *db.DB, src Source) (SourceStatus, error) {
	name := src.Name()
	s := SourceStatus{Source: name}
	if err := d.QueryRowContext(ctx, `SELECT count(*), COALESCE(SUM(chunk_count), 0) FROM kb_documents WHERE source = ?`, name).
		Scan(&s.Docs, &s.Chunks); err != nil {
		return SourceStatus{}, fmt.Errorf("kb: counting %s: %w", name, err)
	}
	state, err := loadState(ctx, d, name)
	if err != nil {
		return SourceStatus{}, fmt.Errorf("kb: loading %s state: %w", name, err)
	}
	s.Cursor, s.LastReconciledAt, s.UpdatedAt = state.Cursor, state.LastReconciledAt, state.UpdatedAt
	s.Progress = 1
	if r, ok := src.(progressReporter); ok {
		if s.Progress, err = r.Progress(ctx, d, state.Cursor); err != nil {
			return SourceStatus{}, fmt.Errorf("kb: %s progress: %w", name, err)
		}
	}
	return s, nil
}

// indexNote explains an empty, partially built or stale index to the search
// caller; "" means the index is complete and fresh.
func indexNote(ctx context.Context, d *db.DB, now time.Time) (string, error) {
	var docs int
	if err := d.QueryRowContext(ctx, `SELECT count(*) FROM kb_documents`).Scan(&docs); err != nil {
		return "", fmt.Errorf("kb: counting documents: %w", err)
	}
	if docs == 0 {
		return "knowledge index is empty — it builds in the background after sync; use list_messages and the source tools meanwhile", nil
	}
	var notes []string
	for _, src := range allSources() {
		r, ok := src.(progressReporter)
		if !ok {
			continue
		}
		state, err := loadState(ctx, d, src.Name())
		if err != nil {
			return "", fmt.Errorf("kb: loading %s state: %w", src.Name(), err)
		}
		behind, err := r.Backfilling(ctx, d, state.Cursor)
		if err != nil {
			return "", fmt.Errorf("kb: %s backfill state: %w", src.Name(), err)
		}
		if !behind {
			continue
		}
		p, err := r.Progress(ctx, d, state.Cursor)
		if err != nil {
			return "", fmt.Errorf("kb: %s progress: %w", src.Name(), err)
		}
		if p < 1 {
			notes = append(notes, fmt.Sprintf("%s %d%% indexed", src.Name(), int(math.Floor(p*100))))
		}
	}
	var last string
	if err := d.QueryRowContext(ctx, `SELECT COALESCE(MAX(updated_at), '') FROM kb_sources`).Scan(&last); err != nil {
		return "", fmt.Errorf("kb: reading last update: %w", err)
	}
	if t, err := time.Parse(isoLayout, last); err == nil && t.Before(now.Add(-staleAfter)) {
		notes = append(notes, "index last updated "+last)
	}
	return strings.Join(notes, "; "), nil
}
