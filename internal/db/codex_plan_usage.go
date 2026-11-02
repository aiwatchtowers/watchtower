package db

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

// CodexPlanUsageStatus keeps identity metadata private to storage. Its embedded
// status is the same publication unit as Claude's, with an independent singleton.
type CodexPlanUsageStatus struct {
	PlanUsageStatus
	Scope                string `json:"-"`
	IdentityKnown        bool   `json:"-"`
	OrdinaryUsageAllowed *bool
}

type CodexPlanUsageSample struct {
	PlanUsageSample
	Scope string `json:"-"`
}

func validPlanScope(scope string) bool {
	b, err := hex.DecodeString(scope)
	return err == nil && len(b) == 32
}

type planExecer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func upsertCodexStatus(ctx context.Context, q planExecer, s CodexPlanUsageStatus) error {
	if s.IdentityKnown && !validPlanScope(s.Scope) || !s.IdentityKnown && s.Scope != "" {
		return errors.New("codex plan usage: invalid identity scope")
	}
	if s.PlotJSON == "" {
		s.PlotJSON = "{}"
	}
	_, err := q.ExecContext(ctx, `INSERT INTO codex_plan_usage_status
		(id, state, reason, plan, fetched_at, last_error, last_error_at, limits_json,
		 breakdown_json, updated_at, plot_json, scope, identity_known, ordinary_usage_allowed)
		VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET state=excluded.state, reason=excluded.reason, plan=excluded.plan,
		fetched_at=excluded.fetched_at, last_error=excluded.last_error, last_error_at=excluded.last_error_at,
		limits_json=excluded.limits_json, breakdown_json=excluded.breakdown_json, updated_at=excluded.updated_at,
		plot_json=excluded.plot_json, scope=excluded.scope, identity_known=excluded.identity_known,
		ordinary_usage_allowed=excluded.ordinary_usage_allowed`,
		s.State, s.Reason, s.Plan, planNullTime(s.FetchedAt), s.LastError, planNullTime(s.LastErrorAt),
		s.LimitsJSON, s.BreakdownJSON, planTime(s.UpdatedAt), s.PlotJSON, s.Scope, s.IdentityKnown, s.OrdinaryUsageAllowed)
	if err != nil {
		return fmt.Errorf("codex plan usage: upsert status: %w", err)
	}
	return nil
}

// UpsertCodexPlanUsageStatus publishes an error/disabled status, retaining good
// values only when the caller has confirmed the matching identity.
func (db *DB) UpsertCodexPlanUsageStatus(s CodexPlanUsageStatus) error {
	return db.UpsertCodexPlanUsageStatusContext(context.Background(), s)
}

// UpsertCodexPlanUsageStatusContext rolls back when the operation is cancelled.
func (db *DB) UpsertCodexPlanUsageStatusContext(ctx context.Context, s CodexPlanUsageStatus) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("codex plan usage: begin status publication: %w", err)
	}
	defer tx.Rollback()
	if err := upsertCodexStatus(ctx, tx, s); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("codex plan usage: commit status publication: %w", err)
	}
	return nil
}

// PublishCodexPlanUsage commits the successful snapshot and all its samples
// together. Unknown identity is allowed for current numbers, never for samples.
func (db *DB) PublishCodexPlanUsage(s CodexPlanUsageStatus, samples []CodexPlanUsageSample) error {
	return db.PublishCodexPlanUsageContext(context.Background(), s, samples)
}

func (db *DB) PublishCodexPlanUsageContext(ctx context.Context, s CodexPlanUsageStatus, samples []CodexPlanUsageSample) error {
	if s.State != "ok" || s.FetchedAt == nil {
		return errors.New("codex plan usage: successful snapshot required")
	}
	if !s.IdentityKnown && len(samples) != 0 {
		return errors.New("codex plan usage: samples require known identity")
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("codex plan usage: begin publication: %w", err)
	}
	defer tx.Rollback()
	if err := upsertCodexStatus(ctx, tx, s); err != nil {
		return err
	}
	for _, sample := range samples {
		if sample.Scope != s.Scope || !sample.TakenAt.Equal(*s.FetchedAt) {
			return errors.New("codex plan usage: sample does not match publication")
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO codex_plan_usage_samples
			(scope, limit_key, taken_at, percent, resets_at) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(scope, limit_key, taken_at) DO UPDATE SET percent=excluded.percent, resets_at=excluded.resets_at`, sample.Scope, sample.LimitKey,
			planTime(sample.TakenAt), sample.Percent, planTime(sample.ResetsAt)); err != nil {
			return fmt.Errorf("codex plan usage: insert sample: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM codex_plan_usage_samples WHERE taken_at < ?`,
		planTime(s.FetchedAt.Add(-8*24*time.Hour))); err != nil {
		return fmt.Errorf("codex plan usage: prune samples: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("codex plan usage: commit publication: %w", err)
	}
	return nil
}

func (db *DB) GetCodexPlanUsageStatus() (*CodexPlanUsageStatus, error) {
	return db.GetCodexPlanUsageStatusContext(context.Background())
}

func (db *DB) GetCodexPlanUsageStatusContext(ctx context.Context) (*CodexPlanUsageStatus, error) {
	var s CodexPlanUsageStatus
	var fetched, lastErrorAt sql.NullString
	var updated string
	var ordinary sql.NullBool
	err := db.QueryRowContext(ctx, `SELECT state, reason, plan, fetched_at, last_error, last_error_at,
		limits_json, breakdown_json, updated_at, plot_json, scope, identity_known, ordinary_usage_allowed
		FROM codex_plan_usage_status WHERE id=1`).Scan(&s.State, &s.Reason, &s.Plan, &fetched,
		&s.LastError, &lastErrorAt, &s.LimitsJSON, &s.BreakdownJSON, &updated, &s.PlotJSON,
		&s.Scope, &s.IdentityKnown, &ordinary)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("codex plan usage: read status: %w", err)
	}
	if s.IdentityKnown && !validPlanScope(s.Scope) || !s.IdentityKnown && s.Scope != "" {
		return nil, errors.New("codex plan usage: invalid stored identity")
	}
	for _, p := range []struct {
		src sql.NullString
		dst **time.Time
	}{{fetched, &s.FetchedAt}, {lastErrorAt, &s.LastErrorAt}} {
		if p.src.Valid && p.src.String != "" {
			t, err := parsePlanTime(p.src.String)
			if err != nil {
				return nil, fmt.Errorf("codex plan usage: read timestamp: %w", err)
			}
			*p.dst = &t
		}
	}
	if s.UpdatedAt, err = parsePlanTime(updated); err != nil {
		return nil, fmt.Errorf("codex plan usage: read updated timestamp: %w", err)
	}
	if ordinary.Valid {
		s.OrdinaryUsageAllowed = &ordinary.Bool
	}
	return &s, nil
}

// CodexPlanUsageHistory never reads another scope, reset, or unpublished poll.
func (db *DB) CodexPlanUsageHistory(scope, key string, since, published, reset time.Time) ([]PlanUsageSample, error) {
	return db.CodexPlanUsageHistoryContext(context.Background(), scope, key, since, published, reset)
}

func (db *DB) CodexPlanUsageHistoryContext(ctx context.Context, scope, key string, since, published, reset time.Time) ([]PlanUsageSample, error) {
	if !validPlanScope(scope) || published.IsZero() || reset.IsZero() {
		return []PlanUsageSample{}, nil
	}
	rows, err := db.QueryContext(ctx, `SELECT taken_at, percent, resets_at FROM codex_plan_usage_samples
		WHERE scope=? AND limit_key=? AND taken_at>=? AND taken_at<=? AND resets_at>=? AND resets_at<=?
		ORDER BY taken_at`, scope, key, planTime(since), planTime(published),
		planTime(reset.Add(-time.Minute)), planTime(reset.Add(time.Minute)))
	if err != nil {
		return nil, fmt.Errorf("codex plan usage: query history: %w", err)
	}
	return readPlanHistory(rows, key)
}

// PlanUsageHistory is the published, same-reset view of Claude's existing data.
// Its schema deliberately has no new identity requirement.
func (db *DB) PlanUsageHistory(key string, since, published, reset time.Time) ([]PlanUsageSample, error) {
	if published.IsZero() || reset.IsZero() {
		return []PlanUsageSample{}, nil
	}
	rows, err := db.Query(`SELECT taken_at, percent, resets_at FROM plan_usage_samples
		WHERE limit_key=? AND taken_at>=? AND taken_at<=? AND resets_at>=? AND resets_at<=? ORDER BY taken_at`,
		key, planTime(since), planTime(published), planTime(reset.Add(-time.Minute)), planTime(reset.Add(time.Minute)))
	if err != nil {
		return nil, fmt.Errorf("plan usage: query published history: %w", err)
	}
	return readPlanHistory(rows, key)
}

func readPlanHistory(rows *sql.Rows, key string) ([]PlanUsageSample, error) {
	defer rows.Close()
	out := []PlanUsageSample{}
	for rows.Next() {
		var taken, reset string
		s := PlanUsageSample{LimitKey: key}
		if err := rows.Scan(&taken, &s.Percent, &reset); err != nil {
			return nil, fmt.Errorf("plan usage: scan history: %w", err)
		}
		var err error
		if s.TakenAt, err = parsePlanTime(taken); err != nil {
			return nil, fmt.Errorf("plan usage: history timestamp: %w", err)
		}
		if s.ResetsAt, err = parsePlanTime(reset); err != nil {
			return nil, fmt.Errorf("plan usage: history reset: %w", err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("plan usage: iterate history: %w", err)
	}
	return out, nil
}
