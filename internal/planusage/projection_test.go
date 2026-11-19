package planusage

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func at(h, m int) time.Time { return time.Date(2026, 10, 15, h, m, 0, 0, time.UTC) }

func series(reset time.Time, start time.Time, step time.Duration, pcts ...float64) []db.PlanUsageSample {
	out := make([]db.PlanUsageSample, len(pcts))
	for i, p := range pcts {
		out[i] = db.PlanUsageSample{LimitKey: "session", TakenAt: start.Add(time.Duration(i) * step), Percent: p, ResetsAt: reset}
	}
	return out
}

func TestProject(t *testing.T) {
	reset := at(13, 0)
	cases := []struct {
		name    string
		now     time.Time
		limit   Limit
		samples []db.PlanUsageSample
		state   string
		hitAt   *time.Time
	}{
		{"hit", at(10, 0), Limit{Group: "session", Percent: 100, ResetsAt: &reset}, nil, "hit", nil},
		{"idle window", at(10, 0), Limit{Group: "session", Percent: 0}, nil, "idle", nil},
		{"collecting", at(10, 10), Limit{Group: "session", Percent: 6, ResetsAt: &reset},
			series(reset, at(10, 0), 5*time.Minute, 4, 5, 6), "collecting", nil},
		{"flat is safe", at(10, 30), Limit{Group: "session", Percent: 10, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 10, 10, 10, 10), "safe", nil},
		// 10%/h for 30 min: 40 → 45 → 50 → 55 at 10:30; 45 % left → 4.5 h → 15:00 > reset 13:00 → safe
		{"slow is safe", at(10, 30), Limit{Group: "session", Percent: 55, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 40, 41.6667, 43.3333, 45), "safe", nil},
		// 60%/h: 40 at 10:00 → 70 at 10:30; 30 % left → 0.5 h → 11:00
		{"will hit", at(10, 30), Limit{Group: "session", Percent: 70, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 40, 50, 60, 70), "will_hit", new(at(11, 0))},
		{"decreasing floors to zero", at(10, 30), Limit{Group: "session", Percent: 30, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 33, 32, 31, 30), "safe", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := project(c.now, c.limit, c.samples)
			assert.Equal(t, c.state, p.State)
			if c.hitAt == nil {
				if c.state != "safe" {
					assert.Nil(t, p.HitAt)
				}
				return
			}
			require.NotNil(t, p.HitAt)
			assert.WithinDuration(t, *c.hitAt, *p.HitAt, time.Minute)
		})
	}
}

func TestProject_NewWindowIgnoresOldSamples(t *testing.T) {
	oldReset, newReset := at(10, 0), at(15, 0)
	samples := append(series(oldReset, at(9, 0), 10*time.Minute, 50, 70, 90),
		series(newReset, at(10, 1), 5*time.Minute, 0, 1)...)
	p := project(at(10, 6), Limit{Group: "session", Percent: 1, ResetsAt: &newReset}, samples)
	assert.Equal(t, "collecting", p.State)
}

func TestProject_LookbackDropsOlderSamples(t *testing.T) {
	reset := at(23, 0)
	// a burst 3 h ago, flat for the last hour → session lookback (1 h) sees flat
	samples := append(series(reset, at(7, 0), 10*time.Minute, 0, 30, 60),
		series(reset, at(9, 30), 10*time.Minute, 60, 60, 60, 60)...)
	p := project(at(10, 0), Limit{Group: "session", Percent: 60, ResetsAt: &reset}, samples)
	assert.Equal(t, "safe", p.State)
}

func TestLookback(t *testing.T) {
	assert.Equal(t, time.Hour, lookback("session"))
	assert.Equal(t, 24*time.Hour, lookback("weekly"))
}

func TestProject_EarlyResetKeepsPostResetPace(t *testing.T) {
	reset := time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)
	now := at(14, 0)
	l := Limit{Group: "weekly", Percent: 32, ResetsAt: &reset}
	start := at(0, 0)
	// Climbs to 95 over a day, resets early (reset time unchanged), then 0 -> 32 in 4 h.
	samples := series(reset, start.Add(-10*time.Hour), time.Hour, 80, 85, 90, 95)
	samples = append(samples, series(reset, at(10, 0), time.Hour, 0, 8, 16, 24, 32)...)
	p := project(now, l, samples)
	assert.Equal(t, "will_hit", p.State)
	assert.InDelta(t, 8, p.RatePerHour, 0.0001)
	require.NotNil(t, p.HitAt)
	assert.True(t, p.HitAt.Equal(now.Add(8*time.Hour+30*time.Minute)), p.HitAt.String())
}

func TestProject_SmallDropIsNotAReset(t *testing.T) {
	reset := at(13, 0)
	// 50 -> 46 is a drop of 4: same window, the fit still sees all samples.
	samples := series(reset, at(10, 0), 10*time.Minute, 50, 46, 52, 58)
	p := project(at(10, 30), Limit{Group: "session", Percent: 58, ResetsAt: &reset}, samples)
	assert.Equal(t, "will_hit", p.State)
	assert.InDelta(t, 18, p.RatePerHour, 0.01)
}

func TestSinceLastReset(t *testing.T) {
	reset := at(13, 0)
	assert.Equal(t, series(reset, at(10, 0), time.Minute, 10, 20, 30), sinceLastReset(series(reset, at(10, 0), time.Minute, 10, 20, 30)))
	got := sinceLastReset(series(reset, at(10, 0), time.Minute, 90, 2, 40, 50, 10, 15))
	require.Len(t, got, 2)
	assert.Equal(t, 10.0, got[0].Percent)
	assert.Empty(t, sinceLastReset(nil))
	// exactly resetDropPercent is a reset; just under it is not
	assert.Len(t, sinceLastReset(series(reset, at(10, 0), time.Minute, 20, 15, 16)), 2)
	assert.Len(t, sinceLastReset(series(reset, at(10, 0), time.Minute, 20, 15.5, 16)), 3)
}
