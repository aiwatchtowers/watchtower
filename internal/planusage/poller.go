package planusage

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"watchtower/internal/claude"
	"watchtower/internal/db"
)

const (
	pollInterval   = 5 * time.Minute
	maxBackoff     = 30 * time.Minute
	firstPollDelay = 10 * time.Second
	retention      = 8 * 24 * time.Hour
)

// Store is the slice of the database the poller uses.
type Store interface {
	InsertPlanUsageSamplesContext(context.Context, []db.PlanUsageSample) error
	PlanUsageSamplesSinceContext(context.Context, string, time.Time) ([]db.PlanUsageSample, error)
	PrunePlanUsageSamplesContext(context.Context, time.Time) (int64, error)
	UpsertPlanUsageStatusContext(context.Context, db.PlanUsageStatus) error
	GetPlanUsageStatusContext(context.Context) (*db.PlanUsageStatus, error)
}

// Poller reads the plan usage through Read (production: claude.ReadUsage)
// and stores the result. Provider.Run schedules it.
type Poller struct {
	Store  Store
	Read   func(context.Context) (claude.UsageSnapshot, error)
	Now    func() time.Time
	Logger *log.Logger

	failures int
}

// PollOnce reads the usage, stores samples + status with the projection,
// prunes old samples, and returns the delay before the next poll. A failure
// stores only a fixed code (spec 2026-11-17 §1, §3); a cancelled poll writes
// nothing.
func (p *Poller) PollOnce(ctx context.Context) (time.Duration, error) {
	previousFailures := p.failures
	defer func() {
		if ctx.Err() != nil {
			p.failures = previousFailures
		}
	}()
	if err := ctx.Err(); err != nil {
		return pollInterval, err
	}
	now := p.Now().UTC().Truncate(time.Second)
	prev, err := p.Store.GetPlanUsageStatusContext(ctx)
	if err != nil {
		return pollInterval, err
	}
	st := db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]"}
	if prev != nil {
		st = *prev
	}
	st.UpdatedAt = now

	snap, err := p.Read(ctx)
	if ctx.Err() != nil {
		return pollInterval, ctx.Err()
	}
	code := "parse"
	if err == nil {
		u, perr := usageFromSnapshot(snap)
		if perr == nil {
			st.Plan = snap.Plan
			return pollInterval, p.storeUsage(ctx, now, st, u)
		}
	} else {
		code = ErrorCode(err)
	}
	delay := pollInterval
	switch code {
	case "cli_missing", "unsupported_cli":
		// Nothing is known about the account: its data stays, hidden by the state.
		p.failures = 0
		st.State = "unavailable"
	case "no_credentials", "unsupported_auth", "cloud_bedrock", "cloud_vertex", "cloud_foundry":
		// Account-level: no plan limits apply, so the old account's label and
		// numbers must not survive into a later state. Samples stay.
		p.failures = 0
		st.State = "unavailable"
		st.Plan, st.LimitsJSON, st.BreakdownJSON, st.PlotJSON, st.PublicationProof = "", "[]", "[]", "{}", ""
	default:
		p.failures++
		delay = backoff(p.failures)
		st.State = "error"
	}
	st.Reason = safeStoredReason(code)
	st.LastError, st.LastErrorAt = "Claude usage: "+code, &now
	if err := p.Store.UpsertPlanUsageStatusContext(ctx, st); err != nil {
		return delay, fmt.Errorf("planusage: write status: %w (while handling: %s)", err, code)
	}
	return delay, &OperationError{Code: code, Cause: err}
}

func backoff(failures int) time.Duration {
	d := pollInterval << (failures - 1)
	if d > maxBackoff || d <= 0 {
		return maxBackoff
	}
	return d
}

func (p *Poller) storeUsage(ctx context.Context, now time.Time, st db.PlanUsageStatus, u Usage) error {
	samples := make([]db.PlanUsageSample, 0, len(u.Limits))
	for _, l := range u.Limits {
		s := db.PlanUsageSample{LimitKey: l.Key, TakenAt: now, Percent: l.Percent}
		if l.ResetsAt != nil {
			s.ResetsAt = *l.ResetsAt
		}
		samples = append(samples, s)
	}
	if err := p.Store.InsertPlanUsageSamplesContext(ctx, samples); err != nil {
		return err
	}
	for i, l := range u.Limits {
		hist, err := p.Store.PlanUsageSamplesSinceContext(ctx, l.Key, now.Add(-lookback(l.Group)))
		if err != nil {
			return err
		}
		u.Limits[i].Projection = project(now, l, hist)
	}
	windows := make([]WindowLimit, 0, len(u.Limits))
	current := map[string]bool{}
	for _, l := range u.Limits {
		w := ClaudeWindowLimit(l)
		windows = append(windows, w)
		current[l.Key] = w.ResetsAt != nil
	}
	limits, err := json.Marshal(u.Limits)
	if err != nil {
		return fmt.Errorf("planusage: encode limits: %w", err)
	}
	plot, proof, err := buildPublication(now, windows, string(limits), true, current)
	if err != nil {
		return fmt.Errorf("planusage: build plot: %w", err)
	}
	breakdown, err := json.Marshal(nonNil(u.Breakdown))
	if err != nil {
		return fmt.Errorf("planusage: encode breakdown: %w", err)
	}
	p.failures = 0
	st.State, st.Reason, st.LastError, st.LastErrorAt = "ok", "", "", nil
	st.FetchedAt = &now
	st.LimitsJSON, st.BreakdownJSON = string(limits), string(breakdown)
	st.PlotJSON, st.PublicationProof = plot, proof
	if err := p.Store.UpsertPlanUsageStatusContext(ctx, st); err != nil {
		return err
	}
	if _, err := p.Store.PrunePlanUsageSamplesContext(ctx, now.Add(-retention)); err != nil {
		p.Logger.Printf("plan usage: prune: %v", err)
	}
	return nil
}

func nonNil(rows []BreakdownRow) []BreakdownRow {
	if rows == nil {
		return []BreakdownRow{}
	}
	return rows
}

// MarkDisabled records that the feature is off, keeping the last numbers.
func MarkDisabled(store Store, now time.Time) error {
	return MarkDisabledContext(context.Background(), store, now)
}

func MarkDisabledContext(ctx context.Context, store Store, now time.Time) error {
	prev, err := store.GetPlanUsageStatusContext(ctx)
	if err != nil {
		return err
	}
	st := db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]"}
	if prev != nil {
		st = *prev
	}
	st.State, st.Reason, st.UpdatedAt = "disabled", "", now.UTC()
	return store.UpsertPlanUsageStatusContext(ctx, st)
}
