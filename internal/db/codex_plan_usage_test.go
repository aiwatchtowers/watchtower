package db

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func codexTestStatus(now time.Time, scope string) CodexPlanUsageStatus {
	return CodexPlanUsageStatus{PlanUsageStatus: PlanUsageStatus{State: "ok", FetchedAt: &now,
		UpdatedAt: now, LimitsJSON: "[]", BreakdownJSON: "[]", PlotJSON: "{}"}, Scope: scope, IdentityKnown: scope != ""}
}

func codexTestSample(now, reset time.Time, scope string, percent float64) CodexPlanUsageSample {
	return CodexPlanUsageSample{Scope: scope, PlanUsageSample: PlanUsageSample{
		LimitKey: "quota", TakenAt: now, Percent: percent, ResetsAt: reset}}
}

func TestCodexPlanUsage_PublicationIsolationAndRollback(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset := now.Add(time.Hour)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	st := codexTestStatus(now, a)
	st.Plan, st.PlotJSON = "pro", `{"candidate":true}`
	st.OrdinaryUsageAllowed = new(false)
	samples := []CodexPlanUsageSample{codexTestSample(now, reset, a, 40)}
	require.NoError(t, d.PublishCodexPlanUsage(st, samples))
	require.NoError(t, d.PublishCodexPlanUsage(st, samples))
	got, err := d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, st, *got)
	encoded, err := json.Marshal(got)
	require.NoError(t, err)
	assert.NotContains(t, string(encoded), a, "scope is storage-private")
	history, err := d.CodexPlanUsageHistory(a, "quota", now.Add(-time.Hour), now, reset)
	require.NoError(t, err)
	require.Len(t, history, 1, "duplicate publication must not duplicate samples")
	// Two serialized fetches can complete in the same second with a new value.
	// Their one stored observation must agree with the latest status publication.
	require.NoError(t, d.PublishCodexPlanUsage(st, []CodexPlanUsageSample{codexTestSample(now, reset, a, 45)}))
	history, err = d.CodexPlanUsageHistory(a, "quota", now.Add(-time.Hour), now, reset)
	require.NoError(t, err)
	require.Len(t, history, 1)
	assert.Equal(t, 45.0, history[0].Percent)
	other, err := d.CodexPlanUsageHistory(b, "quota", now.Add(-time.Hour), now, reset)
	require.NoError(t, err)
	assert.Empty(t, other)

	// A failed insert occurs after the status upsert and must roll it back too.
	later := now.Add(time.Minute)
	bad := codexTestStatus(later, a)
	bad.Plan = "should roll back"
	err = d.PublishCodexPlanUsage(bad, []CodexPlanUsageSample{codexTestSample(later, reset, a, math.Inf(1))})
	require.Error(t, err)
	got, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "pro", got.Plan)
	assert.Equal(t, now, *got.FetchedAt)
	history, err = d.CodexPlanUsageHistory(a, "quota", now.Add(-time.Hour), later, reset)
	require.NoError(t, err)
	assert.Len(t, history, 1)

	unknown := codexTestStatus(later, "")
	require.Error(t, d.PublishCodexPlanUsage(unknown, samples))
	require.NoError(t, d.PublishCodexPlanUsage(unknown, nil))
	got, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.False(t, got.IdentityKnown)
	assert.Empty(t, got.Scope)
	assert.Nil(t, got.OrdinaryUsageAllowed)
	claude, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Nil(t, claude, "Codex never overwrites Claude")
}

func TestCodexPlanUsage_HistoryPublishedResetAndRetention(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset := now.Add(time.Hour)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for _, tc := range []struct {
		at, reset time.Time
		scope     string
	}{
		{now.Add(-9 * 24 * time.Hour), reset, a},
		{now.Add(-8 * 24 * time.Hour), reset, a},
		{now.Add(-4 * time.Minute), reset.Add(-60 * time.Second), a},
		{now.Add(-3 * time.Minute), reset.Add(60 * time.Second), a},
		{now.Add(-2 * time.Minute), reset.Add(61 * time.Second), a},
		{now.Add(-time.Minute), reset, b},
		{now, reset, a},
		{now.Add(time.Minute), reset, a},
	} {
		require.NoError(t, d.PublishCodexPlanUsage(codexTestStatus(tc.at, tc.scope),
			[]CodexPlanUsageSample{codexTestSample(tc.at, tc.reset, tc.scope, 10)}))
	}
	// Publish at now to apply the exact 8-day cutoff.
	require.NoError(t, d.PublishCodexPlanUsage(codexTestStatus(now, a), nil))
	h, err := d.CodexPlanUsageHistory(a, "quota", now.Add(-10*24*time.Hour), now, reset)
	require.NoError(t, err)
	assert.Len(t, h, 3) // the later publication already pruned the -8d boundary
	for _, s := range h {
		assert.False(t, s.TakenAt.After(now))
		assert.LessOrEqual(t, math.Abs(s.ResetsAt.Sub(reset).Seconds()), 60.0)
	}
	h, err = d.CodexPlanUsageHistory("", "quota", time.Time{}, now, reset)
	require.NoError(t, err)
	assert.Empty(t, h)
}

func TestPlanUsage_PublishedHistoryAndPlot(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset := now.Add(time.Hour)
	require.NoError(t, d.InsertPlanUsageSamples([]PlanUsageSample{
		{LimitKey: "session", TakenAt: now.Add(-time.Minute), Percent: 10, ResetsAt: reset.Add(-time.Minute)},
		{LimitKey: "session", TakenAt: now, Percent: 20, ResetsAt: reset.Add(time.Minute)},
		{LimitKey: "session", TakenAt: now.Add(time.Minute), Percent: 30, ResetsAt: reset},
		{LimitKey: "session", TakenAt: now.Add(-2 * time.Minute), Percent: 99, ResetsAt: reset.Add(61 * time.Second)},
	}))
	h, err := d.PlanUsageHistory("session", now.Add(-time.Hour), now, reset)
	require.NoError(t, err)
	assert.Len(t, h, 2)
	s := PlanUsageStatus{State: "ok", FetchedAt: &now, UpdatedAt: now, LimitsJSON: "[]", BreakdownJSON: "[]", PlotJSON: `{"published":1}`}
	require.NoError(t, d.UpsertPlanUsageStatus(s))
	s.State, s.LastError = "error", "safe source error"
	require.NoError(t, d.UpsertPlanUsageStatus(s))
	got, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, s.PlotJSON, got.PlotJSON)
}

func TestCodexPlanUsage_RetentionExactBoundary(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset, scope := now.Add(time.Hour), strings.Repeat("a", 64)
	for _, at := range []time.Time{now.Add(-8*24*time.Hour - time.Second), now.Add(-8 * 24 * time.Hour), now} {
		require.NoError(t, d.PublishCodexPlanUsage(codexTestStatus(at, scope), []CodexPlanUsageSample{codexTestSample(at, reset, scope, 10)}))
	}
	history, err := d.CodexPlanUsageHistory(scope, "quota", now.Add(-9*24*time.Hour), now, reset)
	require.NoError(t, err)
	require.Len(t, history, 2)
	assert.Equal(t, now.Add(-8*24*time.Hour), history[0].TakenAt)
}

func TestCodexPlanUsageMigration_DownUpPreservesClaude(t *testing.T) {
	raw := openRawDBAtVersion(t, 169)
	_, err := raw.Exec(`INSERT INTO plan_usage_status (id,state,limits_json,updated_at,plot_json) VALUES (1,'ok','[]','2026-11-02T09:00:00Z','{"test":1}')`)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(raw, "migrations", 168))
	var state string
	require.NoError(t, raw.QueryRow(`SELECT state FROM plan_usage_status WHERE id=1`).Scan(&state))
	assert.Equal(t, "ok", state)
	require.NoError(t, gooseUp(raw, "migrations"))
	var plot string
	require.NoError(t, raw.QueryRow(`SELECT plot_json FROM plan_usage_status WHERE id=1`).Scan(&plot))
	assert.Equal(t, "{}", plot)
	var count int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM codex_plan_usage_samples`).Scan(&count))
	assert.Zero(t, count)
}
