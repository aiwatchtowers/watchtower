package planusage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

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

// CredentialLoader reads Claude Code's OAuth credentials.
type CredentialLoader interface {
	Load(context.Context) (Credentials, error)
}

// Fetcher GETs the usage body for a token.
type Fetcher interface {
	Fetch(context.Context, string) ([]byte, error)
}

// Poller reads the plan usage on a schedule and stores the result.
type Poller struct {
	Store  Store
	Creds  CredentialLoader
	Client Fetcher
	Now    func() time.Time
	Logger *log.Logger

	failures int
}

// PollOnce reads credentials, fetches, stores samples + status with the
// projection, prunes old samples, and returns the delay before the next poll.
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

	creds, err := p.Creds.Load(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return pollInterval, ctx.Err()
		}
		p.failures = 0
		st.State, st.Reason = "unavailable", "no_credentials"
		return pollInterval, p.save(ctx, st, err)
	}
	st.Plan = creds.Plan
	if !creds.ExpiresAt.IsZero() && !creds.ExpiresAt.After(now) {
		p.failures = 0
		st.State, st.Reason = "stale", "token_expired"
		return pollInterval, p.save(ctx, st, nil)
	}
	body, err := p.Client.Fetch(ctx, creds.AccessToken)
	if err != nil && ctx.Err() != nil {
		return pollInterval, ctx.Err()
	}
	if err == nil {
		var u Usage
		if u, err = parse(body); err == nil {
			if ctx.Err() != nil {
				return pollInterval, ctx.Err()
			}
			return pollInterval, p.storeUsage(ctx, now, st, u)
		}
		err = &parseError{err}
	}
	err = redact(err, creds.AccessToken)
	var he *HTTPError
	if errors.As(err, &he) && he.Status == 401 {
		p.failures = 0
		st.State, st.Reason = "stale", "token_expired"
		return pollInterval, p.fail(ctx, st, now, err)
	}
	p.failures++
	st.State, st.Reason = "error", reasonFor(err)
	return backoff(p.failures), p.fail(ctx, st, now, err)
}

type parseError struct{ error }

func (e *parseError) Unwrap() error { return e.error }

func reasonFor(err error) string {
	var he *HTTPError
	var pe *parseError
	switch {
	case errors.As(err, &he):
		return fmt.Sprintf("http_%d", he.Status)
	case errors.As(err, &pe):
		return "parse"
	default:
		return "network"
	}
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
	plot, err := BuildPlot(now, windows, true, current)
	if err != nil {
		return fmt.Errorf("planusage: build plot: %w", err)
	}
	limits, err := json.Marshal(u.Limits)
	if err != nil {
		return fmt.Errorf("planusage: encode limits: %w", err)
	}
	breakdown, err := json.Marshal(nonNil(u.Breakdown))
	if err != nil {
		return fmt.Errorf("planusage: encode breakdown: %w", err)
	}
	p.failures = 0
	st.State, st.Reason, st.LastError, st.LastErrorAt = "ok", "", "", nil
	st.FetchedAt = &now
	st.LimitsJSON, st.BreakdownJSON = string(limits), string(breakdown)
	st.PlotJSON = plot
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

func (p *Poller) fail(ctx context.Context, st db.PlanUsageStatus, now time.Time, cause error) error {
	st.LastError, st.LastErrorAt = cause.Error(), &now
	return p.save(ctx, st, cause)
}

// save writes st and returns cause; a write error always wins and never wraps cause.
func (p *Poller) save(ctx context.Context, st db.PlanUsageStatus, cause error) error {
	if err := p.Store.UpsertPlanUsageStatusContext(ctx, st); err != nil {
		if cause == nil {
			return err
		}
		// Not joined: Run silences ErrNoCredentials, and a failed write must still be logged.
		return fmt.Errorf("planusage: write status: %w (while handling: %v)", err, cause)
	}
	if cause != nil {
		code := safeStoredReason(st.Reason)
		var timeout interface{ Timeout() bool }
		if errors.Is(cause, context.DeadlineExceeded) || errors.As(cause, &timeout) && timeout.Timeout() {
			code = "timeout"
		}
		return &OperationError{Code: code, Cause: cause}
	}
	return nil
}

// Run polls until ctx ends: first after 10 s, then at PollOnce's delay.
func (p *Poller) Run(ctx context.Context) error {
	timer := time.NewTimer(firstPollDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-timer.C:
			next, err := p.PollOnce(ctx)
			if err != nil && !errors.Is(err, ErrNoCredentials) {
				p.Logger.Printf("plan usage: %v (next poll in %s)", err, next)
			}
			timer.Reset(next)
		}
	}
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
