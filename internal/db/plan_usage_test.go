package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPlanUsageSamples_InsertQueryPrune(t *testing.T) {
	d := openTestDB(t)
	t0 := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	reset := t0.Add(3 * time.Hour)
	require.NoError(t, d.InsertPlanUsageSamples([]PlanUsageSample{
		{LimitKey: "session", TakenAt: t0, Percent: 4, ResetsAt: reset},
		{LimitKey: "session", TakenAt: t0.Add(5 * time.Minute), Percent: 6, ResetsAt: reset},
		{LimitKey: "weekly_all", TakenAt: t0, Percent: 59},
	}))
	got, err := d.PlanUsageSamplesSince("session", t0.Add(time.Minute))
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, 6.0, got[0].Percent)
	assert.True(t, got[0].ResetsAt.Equal(reset))

	weekly, err := d.PlanUsageSamplesSince("weekly_all", t0.Add(-time.Hour))
	require.NoError(t, err)
	require.Len(t, weekly, 1)
	assert.True(t, weekly[0].ResetsAt.IsZero(), "empty resets_at round-trips as zero time")

	n, err := d.PrunePlanUsageSamples(t0.Add(time.Minute))
	require.NoError(t, err)
	assert.Equal(t, int64(2), n)
}

func TestPlanUsageStatus_UpsertGet(t *testing.T) {
	d := openTestDB(t)
	got, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Nil(t, got)

	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertPlanUsageStatus(PlanUsageStatus{State: "ok", Plan: "max", FetchedAt: &now, LimitsJSON: `[{"key":"session"}]`, BreakdownJSON: "[]", UpdatedAt: now}))
	require.NoError(t, d.UpsertPlanUsageStatus(PlanUsageStatus{State: "error", Reason: "http_429", Plan: "max", FetchedAt: &now, LastError: "HTTP 429", LastErrorAt: &now, LimitsJSON: `[{"key":"session"}]`, BreakdownJSON: "[]", UpdatedAt: now}))
	got, err = d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "error", got.State)
	assert.Equal(t, "http_429", got.Reason)
	require.NotNil(t, got.FetchedAt)
	assert.True(t, got.FetchedAt.Equal(now))
	assert.Equal(t, `[{"key":"session"}]`, got.LimitsJSON)
}
