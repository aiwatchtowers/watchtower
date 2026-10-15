package planusage

import (
	"math"
	"time"

	"watchtower/internal/db"
)

const (
	minSpan       = 15 * time.Minute
	rateEpsilon   = 0.01 // percent per hour
	sameWindowTol = 60 * time.Second
)

// Lookback is how far back the rate is fitted: the 5-hour window reacts
// within the hour, the weekly one is smoothed over a day.
func Lookback(group string) time.Duration {
	if group == "session" {
		return time.Hour
	}
	return 24 * time.Hour
}

// Project fits a least-squares line through the limit's samples in the
// current window and lookback and says whether 100 % comes before the reset.
func Project(now time.Time, l Limit, samples []db.PlanUsageSample) Projection {
	if l.Percent >= 100 {
		return Projection{State: "hit"}
	}
	if l.ResetsAt == nil {
		return Projection{State: "idle"}
	}
	from := now.Add(-Lookback(l.Group))
	var xs, ys []float64
	var first, last time.Time
	for _, s := range samples {
		if s.TakenAt.Before(from) || s.TakenAt.After(now) || s.ResetsAt.IsZero() {
			continue
		}
		if d := s.ResetsAt.Sub(*l.ResetsAt); d > sameWindowTol || d < -sameWindowTol {
			continue
		}
		if first.IsZero() {
			first = s.TakenAt
		}
		last = s.TakenAt
		xs = append(xs, s.TakenAt.Sub(first).Hours())
		ys = append(ys, s.Percent)
	}
	if len(xs) < 2 || last.Sub(first) < minSpan {
		return Projection{State: "collecting"}
	}
	rate := math.Max(0, slope(xs, ys))
	if rate < rateEpsilon {
		return Projection{State: "safe"}
	}
	hit := now.Add(time.Duration((100 - l.Percent) / rate * float64(time.Hour)))
	p := Projection{RatePerHour: rate, HitAt: &hit, State: "will_hit"}
	if !hit.Before(*l.ResetsAt) {
		p.State = "safe"
	}
	return p
}

func slope(xs, ys []float64) float64 {
	n := float64(len(xs))
	var sx, sy, sxx, sxy float64
	for i := range xs {
		sx += xs[i]
		sy += ys[i]
		sxx += xs[i] * xs[i]
		sxy += xs[i] * ys[i]
	}
	den := n*sxx - sx*sx
	if den == 0 {
		return 0
	}
	return (n*sxy - sx*sy) / den
}
