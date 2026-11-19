package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// WatchmanWorkbenchState is a workbench's watchman_workbenches row.
type WatchmanWorkbenchState struct {
	EnabledAt          time.Time
	EstimatedDecisions int
	Unlabelled         int
	LearnedThrough     *time.Time // nil until every source finished its backfill
}

// WatchmanWorkbench returns the workbench's Watchman row, nil when Watchman
// is not on there.
func (db *DB) WatchmanWorkbench(workbenchID int64) (*WatchmanWorkbenchState, error) {
	var s WatchmanWorkbenchState
	var enabled string
	var learned sql.NullString
	err := db.QueryRow(`SELECT enabled_at, estimated_decisions, unlabelled, learned_through
		FROM watchman_workbenches WHERE workbench_id = ?`, workbenchID).Scan(&enabled, &s.EstimatedDecisions, &s.Unlabelled, &learned)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading watchman workbench %d: %w", workbenchID, err)
	}
	s.EnabledAt, _ = time.Parse(time.RFC3339, enabled)
	if learned.Valid {
		t, _ := time.Parse(time.RFC3339, learned.String)
		s.LearnedThrough = &t
	}
	return &s, nil
}

// WatchmanPrecedentCounts counts a workbench's precedents per category and
// per source.
func (db *DB) WatchmanPrecedentCounts(workbenchID int64) (byCategory, bySource map[string]int, err error) {
	rows, err := db.Query(`SELECT category, source, COUNT(*) FROM watchman_precedents WHERE workbench_id = ? GROUP BY category, source`, workbenchID)
	if err != nil {
		return nil, nil, fmt.Errorf("counting watchman precedents of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	byCategory, bySource = map[string]int{}, map[string]int{}
	for rows.Next() {
		var cat, src string
		var n int
		if err := rows.Scan(&cat, &src, &n); err != nil {
			return nil, nil, fmt.Errorf("scanning watchman precedent count: %w", err)
		}
		byCategory[cat] += n
		bySource[src] += n
	}
	return byCategory, bySource, rows.Err()
}
