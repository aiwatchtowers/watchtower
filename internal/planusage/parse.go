// Package planusage reads the owner's Claude plan limits (5-hour, weekly,
// per-model weekly) from the endpoint Claude Code's /usage reads, stores
// samples and projects when each limit is hit (spec 2026-10-15).
package planusage

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

// Projection says whether a limit will be hit before its window resets.
type Projection struct {
	State       string     `json:"state"` // idle | collecting | safe | will_hit | hit
	HitAt       *time.Time `json:"hit_at"`
	RatePerHour float64    `json:"rate_per_hour"`
}

// Limit is one plan limit with its current percent and projection.
type Limit struct {
	Key        string     `json:"key"`       // session | weekly_all | weekly_scoped:<slug>
	Label      string     `json:"label"`     // "5-hour" | "Weekly" | "Weekly · Fable"
	Group      string     `json:"group"`     // session | weekly
	Percent    float64    `json:"percent"`   // clamped 0..100
	ResetsAt   *time.Time `json:"resets_at"` // nil = window not started
	Severity   string     `json:"severity"`
	Projection Projection `json:"projection"`
}

// BreakdownRow is one row of the weekly usage breakdown by surface.
type BreakdownRow struct {
	Key     string  `json:"key"`
	Label   string  `json:"label"`
	Percent float64 `json:"percent"`
}

// Usage is the parsed usage response.
type Usage struct {
	Limits    []Limit
	Breakdown []BreakdownRow
}

// errNoLimits means the response carried no usable limit.
var errNoLimits = errors.New("planusage: response has no usable limit")

type rawWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type rawLimit struct {
	Kind     string   `json:"kind"`
	Group    string   `json:"group"`
	Percent  *float64 `json:"percent"`
	Severity string   `json:"severity"`
	ResetsAt *string  `json:"resets_at"`
	Scope    *struct {
		Model *struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
		Surface json.RawMessage `json:"surface"`
	} `json:"scope"`
}

type rawResponse struct {
	FiveHour  *rawWindow `json:"five_hour"`
	SevenDay  *rawWindow `json:"seven_day"`
	Opus      *rawWindow `json:"seven_day_opus"`
	Sonnet    *rawWindow `json:"seven_day_sonnet"`
	Limits    []rawLimit `json:"limits"`
	Breakdown *struct {
		Rows []struct {
			Key         string  `json:"key"`
			DisplayName string  `json:"display_name"`
			Percent     float64 `json:"percent"`
		} `json:"rows"`
	} `json:"seven_day_breakdown"`
}

// parse turns the endpoint's body into limits; unknown keys are ignored and
// every field is optional. limits[] wins; the five_hour/seven_day objects are
// the fallback for responses without it.
func parse(body []byte) (Usage, error) {
	var r rawResponse
	if err := json.Unmarshal(body, &r); err != nil {
		return Usage{}, fmt.Errorf("planusage: decode: %w", err)
	}
	var u Usage
	for _, l := range r.Limits {
		if lim, ok := fromRawLimit(l); ok {
			u.Limits = append(u.Limits, lim)
		}
	}
	if len(u.Limits) == 0 {
		for _, w := range []struct {
			key, label, group string
			win               *rawWindow
		}{
			{"session", "5-hour", "session", r.FiveHour},
			{"weekly_all", "Weekly", "weekly", r.SevenDay},
			{"weekly_scoped:opus", "Weekly · Opus", "weekly", r.Opus},
			{"weekly_scoped:sonnet", "Weekly · Sonnet", "weekly", r.Sonnet},
		} {
			if w.win == nil || w.win.Utilization == nil {
				continue
			}
			u.Limits = append(u.Limits, Limit{Key: w.key, Label: w.label, Group: w.group,
				Percent: clampPercent(*w.win.Utilization), ResetsAt: parseReset(w.win.ResetsAt)})
		}
	}
	if len(u.Limits) == 0 {
		return Usage{}, errNoLimits
	}
	if r.Breakdown != nil {
		for _, row := range r.Breakdown.Rows {
			u.Breakdown = append(u.Breakdown, BreakdownRow{Key: row.Key, Label: row.DisplayName, Percent: row.Percent})
		}
	}
	return u, nil
}

func fromRawLimit(l rawLimit) (Limit, bool) {
	if l.Percent == nil || l.Kind == "" {
		return Limit{}, false
	}
	lim := Limit{Group: l.Group, Percent: clampPercent(*l.Percent), Severity: l.Severity, ResetsAt: parseReset(l.ResetsAt)}
	switch l.Kind {
	case "session":
		lim.Key, lim.Label = "session", "5-hour"
	case "weekly_all":
		lim.Key, lim.Label = "weekly_all", "Weekly"
	default:
		name := scopeName(l)
		if name == "" {
			lim.Key, lim.Label = l.Kind, l.Kind
		} else {
			lim.Key, lim.Label = l.Kind+":"+slug(name), "Weekly · "+name
		}
	}
	if lim.Group == "" {
		lim.Group = "weekly"
		if lim.Key == "session" {
			lim.Group = "session"
		}
	}
	return lim, true
}

func scopeName(l rawLimit) string {
	if l.Scope == nil {
		return ""
	}
	if l.Scope.Model != nil && l.Scope.Model.DisplayName != "" {
		return l.Scope.Model.DisplayName
	}
	var s string
	if json.Unmarshal(l.Scope.Surface, &s) == nil && s != "" {
		return s
	}
	var obj struct {
		DisplayName string `json:"display_name"`
	}
	if json.Unmarshal(l.Scope.Surface, &obj) == nil {
		return obj.DisplayName
	}
	return ""
}

func slug(s string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), " ", "-")
}

func clampPercent(p float64) float64 { return math.Max(0, math.Min(100, p)) }

func parseReset(s *string) *time.Time {
	if s == nil || *s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *s)
	if err != nil {
		return nil
	}
	t = t.UTC()
	return &t
}
