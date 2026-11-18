// Package planusage reads the owner's Claude plan limits (5-hour, weekly,
// per-model weekly) from the installed Claude Code's get_usage answer, stores
// samples and projects when each limit is hit (spec 2026-10-15, 2026-11-17).
package planusage

import (
	"errors"
	"math"
	"strings"
	"time"

	"watchtower/internal/claude"
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

// Usage is one read's limits and breakdown.
type Usage struct {
	Limits    []Limit
	Breakdown []BreakdownRow
}

// errNoLimits means the answer carried no usable limit.
var errNoLimits = errors.New("planusage: response has no usable limit")

// usageFromSnapshot turns a get_usage answer into limits. Percents are
// re-clamped and a non-finite one is dropped; a window without a key (or with
// an empty scoped slug) is dropped and the first window of a key wins, so
// limits_json never carries a duplicate id. The breakdown gets the same
// treatment. No usable window is errNoLimits.
func usageFromSnapshot(s claude.UsageSnapshot) (Usage, error) {
	var u Usage
	seen := map[string]bool{}
	for _, w := range s.Windows {
		if w.Key == "" || strings.HasSuffix(w.Key, ":") || seen[w.Key] || !finite(w.Percent) {
			continue
		}
		seen[w.Key] = true
		u.Limits = append(u.Limits, Limit{Key: w.Key, Label: w.Label, Group: w.Group,
			Percent: clampPercent(w.Percent), ResetsAt: w.ResetsAt})
	}
	if len(u.Limits) == 0 {
		return Usage{}, errNoLimits
	}
	rows := map[string]bool{}
	for _, r := range s.Breakdown {
		if r.Key == "" || rows[r.Key] || !finite(r.Percent) {
			continue
		}
		rows[r.Key] = true
		u.Breakdown = append(u.Breakdown, BreakdownRow{Key: r.Key, Label: r.Label, Percent: clampPercent(r.Percent)})
	}
	return u, nil
}

func clampPercent(p float64) float64 { return math.Max(0, math.Min(100, p)) }
