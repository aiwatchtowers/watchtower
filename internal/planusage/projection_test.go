package planusage

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func at(h, m int) time.Time      { return time.Date(2026, 10, 15, h, m, 0, 0, time.UTC) }
func ptr(t time.Time) *time.Time { return &t }

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
			series(reset, at(10, 0), 10*time.Minute, 40, 50, 60, 70), "will_hit", ptr(at(11, 0))},
		{"decreasing floors to zero", at(10, 30), Limit{Group: "session", Percent: 30, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 60, 50, 40, 30), "safe", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := Project(c.now, c.limit, c.samples)
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
	p := Project(at(10, 6), Limit{Group: "session", Percent: 1, ResetsAt: &newReset}, samples)
	assert.Equal(t, "collecting", p.State)
}

func TestProject_LookbackDropsOlderSamples(t *testing.T) {
	reset := at(23, 0)
	// a burst 3 h ago, flat for the last hour → session lookback (1 h) sees flat
	samples := append(series(reset, at(7, 0), 10*time.Minute, 0, 30, 60),
		series(reset, at(9, 30), 10*time.Minute, 60, 60, 60, 60)...)
	p := Project(at(10, 0), Limit{Group: "session", Percent: 60, ResetsAt: &reset}, samples)
	assert.Equal(t, "safe", p.State)
}

func TestLookback(t *testing.T) {
	assert.Equal(t, time.Hour, Lookback("session"))
	assert.Equal(t, 24*time.Hour, Lookback("weekly"))
}
