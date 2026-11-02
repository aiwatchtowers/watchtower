package planusage

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"time"

	"watchtower/internal/db"
)

// WindowLimit is the storage form used for Codex and the new aggregate reader.
// Claude's legacy Limit and its JSON remain unchanged.
type WindowLimit struct {
	Key                   string     `json:"key"`
	Label                 string     `json:"label"`
	Group                 string     `json:"group"`
	Percent               float64    `json:"percent"`
	WindowDurationMinutes *int64     `json:"window_duration_minutes"`
	ResetsAt              *time.Time `json:"resets_at"`
	Projection            Projection `json:"projection"`
}

// Line is calculated in Go and consumed directly by the Desktop chart.
type Line struct {
	StartAt      time.Time `json:"start_at"`
	StartPercent float64   `json:"start_percent"`
	EndAt        time.Time `json:"end_at"`
	EndPercent   float64   `json:"end_percent"`
}

type Plot struct {
	SchemaVersion int              `json:"schema_version"`
	FetchedAt     time.Time        `json:"fetched_at"`
	Limits        map[string]*Line `json:"limits"`
}

type PublicProjection struct {
	State             string     `json:"state"`
	HitAt             *time.Time `json:"hit_at"`
	RatePerHour       float64    `json:"rate_per_hour"`
	Drawable          bool       `json:"drawable"`
	UnavailableReason *string    `json:"unavailable_reason"`
	Line              *Line      `json:"line"`
}

// ProjectionContext supplies read-time eligibility, without fitting a new rate.
type ProjectionContext struct {
	Now              time.Time
	FeatureEnabled   bool
	State            string
	FetchedAt        *time.Time
	IdentityRequired bool
	IdentityKnown    bool
	HasCurrentSample bool
}

func finite(n float64) bool       { return !math.IsNaN(n) && !math.IsInf(n, 0) }
func percentValid(n float64) bool { return finite(n) && n >= 0 && n <= 100 }
func validProjectionState(s string) bool {
	switch s {
	case "idle", "collecting", "safe", "will_hit", "hit":
		return true
	}
	return false
}

// ClaudeWindowLimit adds known durations without modifying legacy persisted JSON.
func ClaudeWindowLimit(l Limit) WindowLimit {
	var duration *int64
	if l.Group == "session" {
		duration = new(int64(300))
	} else if l.Group == "weekly" {
		duration = new(int64(10080))
	}
	return WindowLimit{Key: l.Key, Label: l.Label, Group: l.Group, Percent: l.Percent,
		WindowDurationMinutes: duration, ResetsAt: l.ResetsAt, Projection: l.Projection}
}

// ProjectWindow reuses the original least-squares policy and lookback verbatim.
func ProjectWindow(now time.Time, l WindowLimit, samples []db.PlanUsageSample) Projection {
	return project(now, Limit{Key: l.Key, Group: l.Group, Percent: l.Percent, ResetsAt: l.ResetsAt}, CurrentWindowSamples(samples, l, now))
}

func utcTimestamp(t time.Time) bool {
	_, offset := t.Zone()
	return offset == 0
}

func windowStart(l WindowLimit) (time.Time, bool) {
	if l.WindowDurationMinutes == nil || *l.WindowDurationMinutes <= 0 ||
		*l.WindowDurationMinutes > math.MaxInt64/int64(time.Minute) || l.ResetsAt == nil {
		return time.Time{}, false
	}
	return l.ResetsAt.Add(-time.Duration(*l.WindowDurationMinutes) * time.Minute), true
}

func validateLine(line *Line, fetched time.Time, l WindowLimit) error {
	start, ok := windowStart(l)
	if !ok || !percentValid(line.StartPercent) || !percentValid(line.EndPercent) ||
		!line.StartAt.Equal(fetched) || line.StartPercent != l.Percent || !line.EndAt.After(line.StartAt) ||
		line.StartAt.Before(start) || line.EndAt.After(*l.ResetsAt) || line.StartAt.After(*l.ResetsAt) {
		return errors.New("plan usage: invalid stored line")
	}
	return nil
}

// DecodePlot distinguishes the sole legacy default {} from corrupted storage.
// It validates every non-null candidate before the read-time gates hide it.
func DecodePlot(text string, fetched *time.Time, limits []WindowLimit) (Plot, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(text), &fields); err != nil || fields == nil {
		return Plot{}, errors.New("plan usage: malformed plot")
	}
	if len(fields) == 0 {
		return Plot{Limits: map[string]*Line{}}, nil
	}
	for _, key := range []string{"schema_version", "fetched_at", "limits"} {
		if _, ok := fields[key]; !ok {
			return Plot{}, errors.New("plan usage: missing plot field")
		}
	}
	var plot Plot
	decoder := json.NewDecoder(bytes.NewBufferString(text))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&plot); err != nil || plot.SchemaVersion != 1 || fetched == nil ||
		!plot.FetchedAt.Equal(*fetched) || plot.FetchedAt.IsZero() || plot.Limits == nil || !utcTimestamp(plot.FetchedAt) {
		return Plot{}, errors.New("plan usage: invalid plot publication")
	}
	known := map[string]WindowLimit{}
	for _, l := range limits {
		known[l.Key] = l
	}
	var rawLines map[string]json.RawMessage
	if err := json.Unmarshal(fields["limits"], &rawLines); err != nil {
		return Plot{}, errors.New("plan usage: invalid plot limits")
	}
	for key, line := range plot.Limits {
		if line == nil {
			continue
		}
		var lineFields map[string]json.RawMessage
		if err := json.Unmarshal(rawLines[key], &lineFields); err != nil || len(lineFields) != 4 {
			return Plot{}, errors.New("plan usage: incomplete stored line")
		}
		for _, field := range []string{"start_at", "start_percent", "end_at", "end_percent"} {
			if value, ok := lineFields[field]; !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				return Plot{}, errors.New("plan usage: incomplete stored line")
			}
		}
		l, ok := known[key]
		if !ok || !utcTimestamp(line.StartAt) || !utcTimestamp(line.EndAt) {
			return Plot{}, errors.New("plan usage: unmatched stored line")
		}
		if err := validateLine(line, *fetched, l); err != nil {
			return Plot{}, err
		}
	}
	return plot, nil
}

// expectedLine serializes the existing projection; it does not fit another rate.
func expectedLine(fetched time.Time, l WindowLimit) *Line {
	p := l.Projection
	if l.ResetsAt == nil || !finite(p.RatePerHour) || p.RatePerHour < 0 {
		return nil
	}
	line := &Line{StartAt: fetched, StartPercent: l.Percent}
	switch p.State {
	case "will_hit":
		if p.HitAt == nil || p.RatePerHour <= 0 || !p.HitAt.After(fetched) || !p.HitAt.Before(*l.ResetsAt) {
			return nil
		}
		line.EndAt, line.EndPercent = p.HitAt.UTC(), 100
	case "safe":
		if p.RatePerHour > 0 && (p.HitAt == nil || p.HitAt.Before(*l.ResetsAt)) {
			return nil
		}
		line.EndAt = l.ResetsAt.UTC()
		line.EndPercent = clampPercent(l.Percent + p.RatePerHour*l.ResetsAt.Sub(fetched).Hours())
	default:
		return nil
	}
	if validateLine(line, fetched, l) != nil {
		return nil
	}
	return line
}

// EvaluateProjection applies the approved ordered gates to a published candidate.
// Unknown stored raw states and invalid candidate geometry are storage failures.
func EvaluateProjection(c ProjectionContext, l WindowLimit, candidate *Line) (PublicProjection, error) {
	p := l.Projection
	out := PublicProjection{State: p.State, HitAt: p.HitAt, RatePerHour: p.RatePerHour}
	if !validProjectionState(p.State) || !percentValid(l.Percent) {
		return out, errors.New("plan usage: invalid stored limit")
	}
	if !finite(out.RatePerHour) || out.RatePerHour < 0 {
		out.RatePerHour = 0
	}
	if candidate != nil {
		if c.FetchedAt == nil {
			return out, errors.New("plan usage: line without publication time")
		}
		if err := validateLine(candidate, *c.FetchedAt, l); err != nil {
			return out, err
		}
	}
	reason := ""
	switch {
	case !c.FeatureEnabled || c.State == "disabled":
		reason = "disabled"
	case c.FetchedAt != nil && c.FetchedAt.After(c.Now.Add(time.Minute)):
		reason = "clock_skew"
	case c.State != "ok" || c.FetchedAt == nil || c.Now.Sub(*c.FetchedAt) > 15*time.Minute:
		reason = "stale"
	case c.IdentityRequired && !c.IdentityKnown:
		reason = "identity_unknown"
	case l.WindowDurationMinutes == nil || *l.WindowDurationMinutes <= 0 || *l.WindowDurationMinutes > math.MaxInt64/int64(time.Minute):
		reason = "missing_window_duration"
	case l.ResetsAt == nil:
		reason = "missing_reset"
	case !l.ResetsAt.After(c.Now):
		reason = "reset_expired"
	case p.State == "idle" || p.State == "collecting" || p.State == "hit":
		reason = p.State
	case !c.HasCurrentSample:
		reason = "collecting"
	case p.HitAt != nil && !p.HitAt.After(c.Now):
		reason = "prediction_expired"
	case candidate == nil:
		reason = "endpoints_unavailable"
	default:
		expected := expectedLine(*c.FetchedAt, l)
		if expected == nil || !candidate.EndAt.Equal(expected.EndAt) || math.Abs(candidate.EndPercent-expected.EndPercent) > 1e-8 {
			reason = "invalid_projection"
		}
	}
	if reason != "" {
		out.UnavailableReason = &reason
		return out, nil
	}
	out.Drawable, out.Line = true, candidate
	return out, nil
}

// BuildPlot publishes candidates from the already-calculated Go projection.
func BuildPlot(fetched time.Time, limits []WindowLimit, identityKnown bool, currentSamples map[string]bool) (string, error) {
	fetched = fetched.UTC()
	plot := Plot{SchemaVersion: 1, FetchedAt: fetched, Limits: map[string]*Line{}}
	for _, l := range limits {
		candidate := expectedLine(fetched, l)
		p, err := EvaluateProjection(ProjectionContext{Now: fetched, FeatureEnabled: true, State: "ok",
			FetchedAt: &fetched, IdentityRequired: true, IdentityKnown: identityKnown,
			HasCurrentSample: currentSamples[l.Key]}, l, candidate)
		if err != nil {
			return "", err
		}
		plot.Limits[l.Key] = p.Line
	}
	b, err := json.Marshal(plot)
	if err != nil {
		return "", fmt.Errorf("plan usage: encode plot: %w", err)
	}
	return string(b), nil
}

// CurrentWindowSamples filters both history and sample eligibility consistently.
func CurrentWindowSamples(samples []db.PlanUsageSample, l WindowLimit, published time.Time) []db.PlanUsageSample {
	out := []db.PlanUsageSample{}
	if l.ResetsAt == nil {
		return out
	}
	for _, s := range samples {
		if s.LimitKey != l.Key || s.TakenAt.After(published) || s.ResetsAt.IsZero() || !percentValid(s.Percent) {
			continue
		}
		if delta := s.ResetsAt.Sub(*l.ResetsAt); delta < -time.Minute || delta > time.Minute {
			continue
		}
		out = append(out, s)
	}
	return out
}
