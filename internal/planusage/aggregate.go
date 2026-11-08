package planusage

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"watchtower/internal/db"
)

type PublicError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func publicError(err error) *PublicError {
	if err == nil {
		return nil
	}
	code := ErrorCode(err)
	switch code {
	case "no_credentials", "unsupported_auth", "cli_missing", "unsupported_cli", "network", "parse", "storage", "busy", "feature_disabled", "cancelled", "timeout":
	default:
		code = "storage"
	}
	return &PublicError{Code: code, Message: "Plan usage: " + code + "."}
}

type PublicLimit struct {
	Key                   string           `json:"key"`
	Label                 string           `json:"label"`
	Group                 string           `json:"group"`
	Percent               float64          `json:"percent"`
	WindowDurationMinutes *int64           `json:"window_duration_minutes"`
	ResetsAt              *time.Time       `json:"resets_at"`
	Projection            PublicProjection `json:"projection"`
}

type PublicStatus struct {
	State                string         `json:"state"`
	Reason               string         `json:"reason"`
	Plan                 string         `json:"plan"`
	FetchedAt            *time.Time     `json:"fetched_at"`
	UpdatedAt            time.Time      `json:"updated_at"`
	LastError            string         `json:"last_error"`
	Stale                bool           `json:"stale"`
	HistoryAvailable     bool           `json:"history_available"`
	OrdinaryUsageAllowed *bool          `json:"ordinary_usage_allowed"`
	Limits               []PublicLimit  `json:"limits"`
	Breakdown            []BreakdownRow `json:"breakdown"`
}

type ProviderResult struct {
	Provider       string        `json:"provider"`
	OK             bool          `json:"ok"`
	Error          *PublicError  `json:"error"`
	RefreshOutcome string        `json:"refresh_outcome"`
	Status         *PublicStatus `json:"status"`
}

type Envelope struct {
	SchemaVersion     int              `json:"schema_version"`
	RequestedProvider string           `json:"requested_provider"`
	RefreshRequested  bool             `json:"refresh_requested"`
	FeatureEnabled    bool             `json:"feature_enabled"`
	Providers         []ProviderResult `json:"providers"`
}

type ReadStore interface {
	GetPlanUsageStatus() (*db.PlanUsageStatus, error)
	GetCodexPlanUsageStatus() (*db.CodexPlanUsageStatus, error)
	PlanUsageHistory(string, time.Time, time.Time, time.Time) ([]db.PlanUsageSample, error)
	CodexPlanUsageHistory(string, string, time.Time, time.Time, time.Time) ([]db.PlanUsageSample, error)
}

func publicTime(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	utc := t.UTC()
	return &utc
}

// ReadStatus uses only already-published data. It never fetches or writes.
func ReadStatus(store ReadStore, provider string, enabled bool, now time.Time) (*PublicStatus, error) {
	source, ok := subscriptionSources[provider]
	if !ok {
		return nil, errors.New("plan usage: unknown subscription source")
	}
	row, err := source.load(store)
	if err != nil || row.status == nil {
		return nil, err
	}
	st, known, ordinary := row.status, row.identityKnown, row.ordinaryUsageAllowed

	switch st.State {
	case "ok", "stale", "unavailable", "error", "disabled":
	default:
		return nil, errors.New("plan usage: invalid stored status")
	}
	limits, err := DecodeWindowLimits(st.LimitsJSON)
	if err != nil {
		return nil, err
	}
	for i, limit := range limits {
		limits[i] = source.normalize(limit)
	}
	plot, err := DecodePlot(st.PlotJSON, st.FetchedAt, limits)
	if err != nil {
		return nil, err
	}
	out := &PublicStatus{State: st.State, Reason: st.Reason, Plan: st.Plan, FetchedAt: publicTime(st.FetchedAt), UpdatedAt: st.UpdatedAt.UTC(),
		OrdinaryUsageAllowed: ordinary, Limits: []PublicLimit{}, Breakdown: []BreakdownRow{}}
	if st.LastError != "" {
		out.LastError = "Plan usage: " + safeStoredReason(st.Reason) + "."
	}
	out.Stale = !enabled || st.State != "ok" || st.FetchedAt == nil || now.Sub(*st.FetchedAt) > 15*time.Minute || st.FetchedAt.After(now.Add(time.Minute))
	if !enabled {
		out.State = "disabled"
	}
	if source.identityRequired && !known && st.State != "ok" {
		return out, nil
	}
	if err := json.Unmarshal([]byte(st.BreakdownJSON), &out.Breakdown); err != nil || out.Breakdown == nil {
		return nil, errors.New("plan usage: invalid stored breakdown")
	}
	var breakdownFields []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(st.BreakdownJSON), &breakdownFields); err != nil {
		return nil, errors.New("plan usage: invalid stored breakdown")
	}
	for i, b := range out.Breakdown {
		if value, ok := breakdownFields[i]["percent"]; !ok || string(value) == "null" || !percentValid(b.Percent) {
			return nil, errors.New("plan usage: invalid stored breakdown percent")
		}
	}
	for _, l := range limits {
		hasSample := false
		if st.FetchedAt != nil && l.ResetsAt != nil && (!source.identityRequired || known) {
			since := st.FetchedAt.Add(-retention)
			if start, ok := windowStart(l); ok {
				since = start
			}
			samples, err := source.history(store, row, l.Key, since, *st.FetchedAt, *l.ResetsAt)
			if err != nil {
				return nil, err
			}
			hasSample = len(CurrentWindowSamples(samples, l, *st.FetchedAt)) > 0
			out.HistoryAvailable = out.HistoryAvailable || hasSample
		}
		projection, err := EvaluateProjection(ProjectionContext{Now: now, FeatureEnabled: enabled, State: st.State, FetchedAt: st.FetchedAt,
			IdentityRequired: source.identityRequired, IdentityKnown: known, HasCurrentSample: hasSample}, l, plot.Limits[l.Key])
		if err != nil {
			return nil, err
		}
		projection.HitAt = publicTime(projection.HitAt)
		out.Limits = append(out.Limits, PublicLimit{Key: l.Key, Label: l.Label, Group: l.Group, Percent: l.Percent,
			WindowDurationMinutes: l.WindowDurationMinutes, ResetsAt: publicTime(l.ResetsAt), Projection: projection})
	}
	return out, nil
}

func safeStoredReason(reason string) string {
	switch reason {
	case "no_credentials", "unsupported_auth", "cli_missing", "unsupported_cli", "network", "parse", "timeout":
		return reason
	case "token_expired", "http_401":
		return "no_credentials"
	}
	return "network"
}

// Collect runs sources independently, including after another source fails.
// read is called after each refresh; operation errors do not erase readable data.
func Collect(ctx context.Context, requested string, refresh, enabled bool, read func(string) (*PublicStatus, error), refreshers map[string]func(context.Context) error) Envelope {
	names := []string{requested}
	if requested == "all" {
		names = Sources()
	}
	out := Envelope{SchemaVersion: 1, RequestedProvider: requested, RefreshRequested: refresh, FeatureEnabled: enabled, Providers: make([]ProviderResult, len(names))}
	var wg sync.WaitGroup
	for i, name := range names {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := ProviderResult{Provider: name, RefreshOutcome: "not_requested"}
			var operationErr error
			if refresh {
				if !enabled {
					operationErr = &OperationError{Code: "feature_disabled"}
				} else if fn := refreshers[name]; fn != nil {
					operationErr = fn(ctx)
				} else {
					operationErr = &OperationError{Code: "storage"}
				}
				r.RefreshOutcome = "updated"
				if operationErr != nil {
					switch ErrorCode(operationErr) {
					case "feature_disabled":
						r.RefreshOutcome = "disabled"
					case "busy":
						r.RefreshOutcome = "busy"
					case "cancelled":
						r.RefreshOutcome = "cancelled"
					default:
						r.RefreshOutcome = "failed"
					}
				}
			}
			status, readErr := read(name)
			if readErr == nil {
				r.Status = status
			}
			if operationErr == nil && readErr != nil {
				operationErr = &OperationError{Code: "storage", Cause: readErr}
			}
			r.Error = publicError(operationErr)
			r.OK = r.Error == nil
			out.Providers[i] = r
		}()
	}
	wg.Wait()
	for _, r := range out.Providers {
		if r.Error != nil && r.Error.Code == "feature_disabled" {
			out.FeatureEnabled = false
		}
	}
	return out
}

// ExitCode centralizes the priority, including disabled + retained read failure.
func ExitCode(e Envelope, signal int) int {
	if signal == 2 {
		return 130
	}
	if signal == 15 {
		return 143
	}
	if e.RefreshRequested && !e.FeatureEnabled {
		return 3
	}
	for _, p := range e.Providers {
		if !p.OK {
			return 1
		}
	}
	return 0
}
