package planusage

import (
	"encoding/json"
	"math"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func plotFixture() (ProjectionContext, WindowLimit, *Line) {
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset, hit := now.Add(2*time.Hour), now.Add(6*time.Hour)
	m := int64(300)
	l := WindowLimit{Key: "session", Label: "5 hours", Group: "session", Percent: 40,
		WindowDurationMinutes: &m, ResetsAt: &reset, Projection: Projection{State: "safe", RatePerHour: 10, HitAt: &hit}}
	return ProjectionContext{Now: now, FeatureEnabled: true, State: "ok", FetchedAt: &now,
			IdentityRequired: true, IdentityKnown: true, HasCurrentSample: true}, l,
		&Line{StartAt: now, StartPercent: 40, EndAt: reset, EndPercent: 60}
}

func TestEvaluateProjection_OrderedGates(t *testing.T) {
	cases := []struct {
		name, reason string
		change       func(*ProjectionContext, *WindowLimit, **Line)
	}{
		{"fresh", "", func(*ProjectionContext, *WindowLimit, **Line) {}},
		{"900s fresh", "", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.Now = c.Now.Add(900 * time.Second) }},
		{"901s stale", "stale", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.Now = c.Now.Add(901 * time.Second) }},
		{"future60 fresh", "", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.Now = c.Now.Add(-60 * time.Second) }},
		{"future61 skew", "clock_skew", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.Now = c.Now.Add(-61 * time.Second) }},
		{"disabled before stale identity", "disabled", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			c.FeatureEnabled = false
			c.State = "error"
			c.IdentityKnown = false
		}},
		{"state disabled", "disabled", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.State = "disabled" }},
		{"source error", "stale", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.State = "error"; c.IdentityKnown = false }},
		{"no fetched", "stale", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.FetchedAt = nil; *p = nil }},
		{"identity", "identity_unknown", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			c.IdentityKnown = false
			l.WindowDurationMinutes = nil
			*p = nil
		}},
		{"Claude no identity gate", "", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			c.IdentityRequired = false
			c.IdentityKnown = false
		}},
		{"missing duration", "missing_window_duration", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.WindowDurationMinutes = nil; *p = nil }},
		{"zero duration", "missing_window_duration", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.WindowDurationMinutes = new(int64(0))
			*p = nil
		}},
		{"missing reset", "missing_reset", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.ResetsAt = nil; *p = nil }},
		{"reset equals now", "reset_expired", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.ResetsAt = new(c.Now); *p = nil }},
		{"reset before now", "reset_expired", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.ResetsAt = new(c.Now.Add(-time.Second))
			*p = nil
		}},
		{"idle", "idle", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.State = "idle"; *p = nil }},
		{"collecting", "collecting", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.State = "collecting"; *p = nil }},
		{"hit", "hit", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.State = "hit"
			l.Percent = 100
			*p = nil
		}},
		{"no current sample", "collecting", func(c *ProjectionContext, l *WindowLimit, p **Line) { c.HasCurrentSample = false }},
		{"hit equals now", "prediction_expired", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.HitAt = new(c.Now) }},
		{"hit before now", "prediction_expired", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.HitAt = new(c.Now.Add(-time.Second))
		}},
		{"no endpoints", "endpoints_unavailable", func(c *ProjectionContext, l *WindowLimit, p **Line) { *p = nil }},
		{"negative rate", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.RatePerHour = -1 }},
		{"nonfinite rate", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.RatePerHour = math.NaN() }},
		{"infinite rate", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.RatePerHour = math.Inf(1) }},
		{"positive safe without hit", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.HitAt = nil }},
		{"safe hit before reset", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { l.Projection.HitAt = new(c.Now.Add(time.Hour)) }},
		{"contradictory endpoint", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) { (*p).EndPercent = 61 }},
		{"will hit at reset", "invalid_projection", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.State = "will_hit"
			l.Projection.HitAt = l.ResetsAt
		}},
		{"flat safe", "", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.RatePerHour = 0
			l.Projection.HitAt = nil
			(*p).EndPercent = 40
		}},
		{"safe hit equals reset", "", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.RatePerHour = 30
			l.Projection.HitAt = l.ResetsAt
			(*p).EndPercent = 100
		}},
		{"valid will hit", "", func(c *ProjectionContext, l *WindowLimit, p **Line) {
			l.Projection.State = "will_hit"
			l.Projection.RatePerHour = 60
			l.Projection.HitAt = new(c.Now.Add(time.Hour))
			(*p).EndAt = *l.Projection.HitAt
			(*p).EndPercent = 100
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, l, line := plotFixture()
			tc.change(&c, &l, &line)
			p, err := EvaluateProjection(c, l, line)
			require.NoError(t, err)
			if tc.reason == "" {
				assert.True(t, p.Drawable)
				require.NotNil(t, p.Line)
				assert.Nil(t, p.UnavailableReason)
			} else {
				assert.False(t, p.Drawable)
				assert.Nil(t, p.Line)
				require.NotNil(t, p.UnavailableReason)
				assert.Equal(t, tc.reason, *p.UnavailableReason)
			}
			assert.True(t, finite(p.RatePerHour))
			assert.GreaterOrEqual(t, p.RatePerHour, 0.0)
			_, err = json.Marshal(p)
			require.NoError(t, err)
		})
	}
}

func TestDecodePlot_DefaultCorruptionAndLineValidation(t *testing.T) {
	c, l, _ := plotFixture()
	text, err := BuildPlot(*c.FetchedAt, []WindowLimit{l}, true, map[string]bool{l.Key: true})
	require.NoError(t, err)
	plot, err := DecodePlot(text, c.FetchedAt, []WindowLimit{l})
	require.NoError(t, err)
	require.NotNil(t, plot.Limits[l.Key])
	for _, raw := range []string{"{}", `{"schema_version":1,"fetched_at":"2026-11-02T09:00:00Z","limits":{}}`, `{"schema_version":1,"fetched_at":"2026-11-02T09:00:00Z","limits":{"session":null}}`} {
		p, err := DecodePlot(raw, c.FetchedAt, []WindowLimit{l})
		require.NoError(t, err)
		public, err := EvaluateProjection(c, l, p.Limits[l.Key])
		require.NoError(t, err)
		require.NotNil(t, public.UnavailableReason)
		assert.Equal(t, "endpoints_unavailable", *public.UnavailableReason)
	}
	mutations := map[string]func(map[string]any){
		"schema":           func(m map[string]any) { m["schema_version"] = 2 },
		"fetched mismatch": func(m map[string]any) { m["fetched_at"] = "2026-11-02T09:00:01Z" },
		"missing field":    func(m map[string]any) { delete(m, "limits") },
		"null limits":      func(m map[string]any) { m["limits"] = nil },
		"null fetched":     func(m map[string]any) { m["fetched_at"] = nil },
		"missing percent": func(m map[string]any) {
			delete(m["limits"].(map[string]any)["session"].(map[string]any), "start_percent")
		},
		"null percent": func(m map[string]any) {
			m["limits"].(map[string]any)["session"].(map[string]any)["start_percent"] = nil
		},
		"wrong start": func(m map[string]any) { m["limits"].(map[string]any)["session"].(map[string]any)["start_percent"] = 41 },
		"end before start": func(m map[string]any) {
			m["limits"].(map[string]any)["session"].(map[string]any)["end_at"] = "2026-11-02T08:00:00Z"
		},
		"end outside window": func(m map[string]any) {
			m["limits"].(map[string]any)["session"].(map[string]any)["end_at"] = "2026-11-02T12:00:00Z"
		},
		"percent outside range": func(m map[string]any) { m["limits"].(map[string]any)["session"].(map[string]any)["end_percent"] = 101 },
	}
	for name, change := range mutations {
		t.Run(name, func(t *testing.T) {
			var m map[string]any
			require.NoError(t, json.Unmarshal([]byte(text), &m))
			change(m)
			b, err := json.Marshal(m)
			require.NoError(t, err)
			_, err = DecodePlot(string(b), c.FetchedAt, []WindowLimit{l})
			require.Error(t, err)
		})
	}
	for _, bad := range []string{"null", "[]", "bad", `{"schema_version":1}`} {
		_, err := DecodePlot(bad, c.FetchedAt, []WindowLimit{l})
		require.Error(t, err)
	}
	l.Projection.State = "unknown"
	_, err = EvaluateProjection(c, l, nil)
	require.Error(t, err)
}

func TestCurrentWindowSamples_BoundsAndProjectionReuse(t *testing.T) {
	c, l, _ := plotFixture()
	published := *c.FetchedAt
	samples := []db.PlanUsageSample{
		{LimitKey: l.Key, TakenAt: published.Add(-20 * time.Minute), Percent: 20, ResetsAt: l.ResetsAt.Add(-60 * time.Second)},
		{LimitKey: l.Key, TakenAt: published, Percent: 40, ResetsAt: l.ResetsAt.Add(60 * time.Second)},
		{LimitKey: l.Key, TakenAt: published.Add(time.Second), Percent: 99, ResetsAt: *l.ResetsAt},
		{LimitKey: l.Key, TakenAt: published.Add(-time.Minute), Percent: 99, ResetsAt: l.ResetsAt.Add(61 * time.Second)},
		{LimitKey: "other", TakenAt: published, Percent: 99, ResetsAt: *l.ResetsAt},
	}
	h := CurrentWindowSamples(samples, l, published)
	require.Len(t, h, 2)
	p := ProjectWindow(published, l, h)
	assert.Equal(t, "will_hit", p.State)
	assert.InDelta(t, 60, p.RatePerHour, 0.0001)
	assert.Equal(t, project(published, Limit{Key: l.Key, Group: l.Group, Percent: l.Percent, ResetsAt: l.ResetsAt}, h), p)
}

func TestClaudeWindowLimit_KnownDurationsOnly(t *testing.T) {
	for _, tc := range []struct {
		group    string
		duration *int64
	}{
		{"session", new(int64(300))}, {"weekly", new(int64(10080))}, {"future_group", nil},
	} {
		l := ClaudeWindowLimit(Limit{Key: "quota", Group: tc.group})
		assert.Equal(t, tc.duration, l.WindowDurationMinutes)
		assert.Equal(t, tc.group, l.Group)
	}
}

func TestProjection_SharedSwiftFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/projection_v1.json")
	require.NoError(t, err)
	var fixture struct {
		Plot       json.RawMessage  `json:"plot_json"`
		Limit      WindowLimit      `json:"limit"`
		Projection PublicProjection `json:"projection"`
	}
	require.NoError(t, json.Unmarshal(b, &fixture))
	c, l, _ := plotFixture()
	assert.Equal(t, l, fixture.Limit)
	p, err := DecodePlot(string(fixture.Plot), c.FetchedAt, []WindowLimit{l})
	require.NoError(t, err)
	public, err := EvaluateProjection(c, l, p.Limits[l.Key])
	require.NoError(t, err)
	assert.Equal(t, public, fixture.Projection)
	encoded, err := json.Marshal(public)
	require.NoError(t, err)
	var fields map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(encoded, &fields))
	assert.Len(t, fields, 6)
	assert.Contains(t, fields, "line")
	assert.NotEqual(t, "null", string(fields["line"]))
	for _, forbidden := range []string{"accountId", "email", "scope"} {
		assert.NotContains(t, string(b), forbidden)
	}
}
