package db

import (
	"database/sql"
	"fmt"
	"time"
)

// PlanUsageSample is one poll's percent of one Claude plan limit
// (spec 2026-10-15 "Storage"). A zero ResetsAt means the window has not started.
type PlanUsageSample struct {
	LimitKey string
	TakenAt  time.Time
	Percent  float64
	ResetsAt time.Time
}

// PlanUsageStatus is the singleton plan_usage_status row the daemon writes and
// the Desktop and `usage plan` read; LimitsJSON already carries the projection.
type PlanUsageStatus struct {
	State, Reason, Plan       string
	FetchedAt                 *time.Time
	LastError                 string
	LastErrorAt               *time.Time
	LimitsJSON, BreakdownJSON string
	UpdatedAt                 time.Time
}

func planTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	// Whole seconds, fixed width: string comparison in SQL then matches time
	// order (RFC3339Nano trims trailing zeros, so "…00.5Z" < "…00Z").
	return t.UTC().Truncate(time.Second).Format(time.RFC3339)
}

func parsePlanTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, s) // also accepts a fractional part
}

func planNullTime(t *time.Time) sql.NullString {
	if t == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: planTime(*t), Valid: true}
}

// InsertPlanUsageSamples writes one poll's samples in one transaction; a
// repeated (limit_key, taken_at) is ignored.
func (db *DB) InsertPlanUsageSamples(samples []PlanUsageSample) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("plan usage samples: begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit
	for _, s := range samples {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO plan_usage_samples (taken_at, limit_key, percent, resets_at) VALUES (?, ?, ?, ?)`,
			planTime(s.TakenAt), s.LimitKey, s.Percent, planTime(s.ResetsAt)); err != nil {
			return fmt.Errorf("plan usage samples: insert %s: %w", s.LimitKey, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("plan usage samples: commit: %w", err)
	}
	return nil
}

// PlanUsageSamplesSince returns limitKey's samples taken at or after since,
// oldest first.
func (db *DB) PlanUsageSamplesSince(limitKey string, since time.Time) ([]PlanUsageSample, error) {
	rows, err := db.Query(`SELECT taken_at, percent, resets_at FROM plan_usage_samples
		WHERE limit_key = ? AND taken_at >= ? ORDER BY taken_at`, limitKey, planTime(since))
	if err != nil {
		return nil, fmt.Errorf("plan usage samples: query %s: %w", limitKey, err)
	}
	defer rows.Close()
	var out []PlanUsageSample
	for rows.Next() {
		var taken, resets string
		s := PlanUsageSample{LimitKey: limitKey}
		if err := rows.Scan(&taken, &s.Percent, &resets); err != nil {
			return nil, fmt.Errorf("plan usage samples: scan: %w", err)
		}
		if s.TakenAt, err = parsePlanTime(taken); err != nil {
			return nil, fmt.Errorf("plan usage samples: taken_at %q: %w", taken, err)
		}
		if s.ResetsAt, err = parsePlanTime(resets); err != nil {
			return nil, fmt.Errorf("plan usage samples: resets_at %q: %w", resets, err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// PrunePlanUsageSamples deletes samples taken before the cutoff.
func (db *DB) PrunePlanUsageSamples(before time.Time) (int64, error) {
	res, err := db.Exec(`DELETE FROM plan_usage_samples WHERE taken_at < ?`, planTime(before))
	if err != nil {
		return 0, fmt.Errorf("plan usage samples: prune: %w", err)
	}
	return res.RowsAffected()
}

// UpsertPlanUsageStatus replaces the singleton status row.
func (db *DB) UpsertPlanUsageStatus(s PlanUsageStatus) error {
	_, err := db.Exec(`INSERT INTO plan_usage_status
		(id, state, reason, plan, fetched_at, last_error, last_error_at, limits_json, breakdown_json, updated_at)
		VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET state=excluded.state, reason=excluded.reason, plan=excluded.plan,
		fetched_at=excluded.fetched_at, last_error=excluded.last_error, last_error_at=excluded.last_error_at,
		limits_json=excluded.limits_json, breakdown_json=excluded.breakdown_json, updated_at=excluded.updated_at`,
		s.State, s.Reason, s.Plan, planNullTime(s.FetchedAt), s.LastError, planNullTime(s.LastErrorAt),
		s.LimitsJSON, s.BreakdownJSON, planTime(s.UpdatedAt))
	if err != nil {
		return fmt.Errorf("plan usage status: upsert: %w", err)
	}
	return nil
}

// GetPlanUsageStatus reads the singleton row; nil, nil before the first write.
func (db *DB) GetPlanUsageStatus() (*PlanUsageStatus, error) {
	var s PlanUsageStatus
	var fetched, lastErrAt sql.NullString
	var updated string
	err := db.QueryRow(`SELECT state, reason, plan, fetched_at, last_error, last_error_at, limits_json, breakdown_json, updated_at
		FROM plan_usage_status WHERE id = 1`).Scan(&s.State, &s.Reason, &s.Plan, &fetched, &s.LastError, &lastErrAt, &s.LimitsJSON, &s.BreakdownJSON, &updated)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("plan usage status: read: %w", err)
	}
	for _, p := range []struct {
		src sql.NullString
		dst **time.Time
	}{{fetched, &s.FetchedAt}, {lastErrAt, &s.LastErrorAt}} {
		if p.src.Valid && p.src.String != "" {
			t, err := parsePlanTime(p.src.String)
			if err != nil {
				return nil, fmt.Errorf("plan usage status: time %q: %w", p.src.String, err)
			}
			*p.dst = &t
		}
	}
	if s.UpdatedAt, err = parsePlanTime(updated); err != nil {
		return nil, fmt.Errorf("plan usage status: updated_at %q: %w", updated, err)
	}
	return &s, nil
}
