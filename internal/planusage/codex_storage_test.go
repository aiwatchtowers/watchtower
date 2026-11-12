package planusage

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
	"watchtower/internal/codex/codextest"
	"watchtower/internal/db"
)

// readFakeCodexUsage runs the real reader (codex.ReadUsageFrom) against an
// in-process app-server, in a synctest bubble: the server answers only the
// allowed methods, rateLimits/read with limits.
func readFakeCodexUsage(t *testing.T, limits json.RawMessage, home string) codex.UsageSnapshot {
	t.Helper()
	var out codex.UsageSnapshot
	synctest.Test(t, func(t *testing.T) {
		server := codextest.New(func(m codextest.Message) []any {
			switch m.Method {
			case "initialize":
				return []any{codextest.Result(m, map[string]any{})}
			case "initialized":
				return nil
			case "account/read":
				return []any{codextest.Result(m, map[string]any{"account": map[string]any{"type": "chatgpt", "planType": "pro", "email": "identity-canary@example.com"}})}
			case "account/rateLimits/read":
				return []any{codextest.Result(m, limits)}
			}
			t.Errorf("unexpected app-server method %q", m.Method)
			return nil
		})
		var err error
		out, err = codex.ReadUsageFrom(t.Context(), func() (codex.AppServerConn, error) { return server.Serve(), nil }, home)
		require.NoError(t, err)
	})
	return out
}

func TestCodexStorage_RealReaderToAtomicSnapshot(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, d.Close()) })
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset := now.Add(2 * time.Hour).Unix()
	raw := fmt.Sprintf(`{"accountId":"account-canary","ordinaryUsageAllowed":false,"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":%d},"secondary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":%d}},"extra":{"primary":{"usedPercent":5,"windowDurationMins":90,"resetsAt":%d}}}}`, reset, reset, reset)
	response := readFakeCodexUsage(t, json.RawMessage(raw), "synthetic-home")
	require.True(t, response.IdentityKnown)
	require.NoError(t, StoreCodexUsage(d, now, response))
	st, err := d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	require.NotNil(t, st)
	assert.Equal(t, response.Scope, st.Scope)
	require.NotNil(t, st.OrdinaryUsageAllowed)
	assert.False(t, *st.OrdinaryUsageAllowed)
	limits, err := VisibleCodexLimits(*st)
	require.NoError(t, err)
	require.Len(t, limits, 3)
	assert.Equal(t, "weekly", limits[0].Group)
	assert.Equal(t, "session", limits[1].Group)
	assert.Equal(t, "window", limits[2].Group)
	plot, err := DecodePlot(st.PlotJSON, st.FetchedAt, limits)
	require.NoError(t, err)
	for _, l := range limits {
		assert.Equal(t, "collecting", l.Projection.State)
		assert.Nil(t, plot.Limits[l.Key])
	}

	// The second sample spans >=15 minutes, enabling the existing Go fit.
	later := now.Add(20 * time.Minute)
	for i := range response.Quotas {
		response.Quotas[i].UsedPercent += 10
	}
	require.NoError(t, StoreCodexUsage(d, later, response))
	require.NoError(t, StoreCodexUsage(d, later, response)) // duplicate is idempotent
	st, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	limits, err = VisibleCodexLimits(*st)
	require.NoError(t, err)
	plot, err = DecodePlot(st.PlotJSON, st.FetchedAt, limits)
	require.NoError(t, err)
	for _, l := range limits {
		h, err := d.CodexPlanUsageHistory(response.Scope, l.Key, now, later, *l.ResetsAt)
		require.NoError(t, err)
		require.Len(t, h, 2)
		assert.InDelta(t, 30, l.Projection.RatePerHour, 0.0001)
		if *l.WindowDurationMinutes >= 300 {
			assert.NotNil(t, plot.Limits[l.Key])
		} // the 90-minute window has not started at fetchedAt
	}
	for _, text := range []string{st.LimitsJSON, st.PlotJSON} {
		assert.NotContains(t, text, "account-canary")
		assert.NotContains(t, text, "identity-canary")
		assert.NotContains(t, text, response.Scope)
	}
}

func testCodexSnapshot(scope string, reset time.Time, percent float64) codex.UsageSnapshot {
	m, r := int64(300), reset.Unix()
	return codex.UsageSnapshot{Scope: scope, IdentityKnown: scope != "", PlanType: "pro", Quotas: []codex.UsageQuota{{Key: "quota", Bucket: "codex", Slot: "primary", UsedPercent: percent, DurationMinutes: &m, ResetsAt: &r}}}
}

func TestCodexStorage_UnknownIdentityAccountSwitchAndFailure(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, d.Close()) })
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	reset := now.Add(time.Hour)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	require.NoError(t, StoreCodexUsage(d, now, testCodexSnapshot(a, reset, 10)))
	require.NoError(t, StoreCodexUsage(d, now.Add(20*time.Minute), testCodexSnapshot(a, reset, 50)))
	st, err := d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	limits, err := VisibleCodexLimits(*st)
	require.NoError(t, err)
	assert.Equal(t, "will_hit", limits[0].Projection.State)
	// Account B cannot fit account A's samples.
	require.NoError(t, StoreCodexUsage(d, now.Add(21*time.Minute), testCodexSnapshot(b, reset, 80)))
	st, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	limits, err = VisibleCodexLimits(*st)
	require.NoError(t, err)
	assert.Equal(t, "collecting", limits[0].Projection.State)
	assert.Equal(t, 80.0, limits[0].Percent)
	// A successful unknown-ID result exposes exactly its own values, no samples.
	require.NoError(t, StoreCodexUsage(d, now.Add(22*time.Minute), testCodexSnapshot("", reset, 7)))
	st, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.False(t, st.IdentityKnown)
	limits, err = VisibleCodexLimits(*st)
	require.NoError(t, err)
	require.Len(t, limits, 1)
	assert.Equal(t, 7.0, limits[0].Percent)
	plot, err := DecodePlot(st.PlotJSON, st.FetchedAt, limits)
	require.NoError(t, err)
	assert.Nil(t, plot.Limits["quota"])
	var count int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM codex_plan_usage_samples`).Scan(&count))
	assert.Equal(t, 3, count)
	// Restore a known snapshot, then fail without identity confirmation.
	require.NoError(t, StoreCodexUsage(d, now.Add(23*time.Minute), testCodexSnapshot(b, reset, 81)))
	good, err := d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	require.NoError(t, StoreCodexFailure(d, now.Add(24*time.Minute), codex.UsageSnapshot{}, "network"))
	st, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.False(t, st.IdentityKnown)
	assert.Empty(t, st.Scope)
	assert.Equal(t, good.PlotJSON, st.PlotJSON)
	assert.Equal(t, good.FetchedAt, st.FetchedAt)
	limits, err = VisibleCodexLimits(*st)
	require.NoError(t, err)
	assert.Empty(t, limits)
	assert.Equal(t, "Codex usage: network", st.LastError)
	require.Error(t, StoreCodexFailure(d, now, codex.UsageSnapshot{}, "raw error identity-canary@example.com"))
	// Current confirmed identity can retain same-account diagnostics on parse error.
	require.NoError(t, StoreCodexUsage(d, now.Add(25*time.Minute), testCodexSnapshot(b, reset, 82)))
	require.NoError(t, StoreCodexFailure(d, now.Add(26*time.Minute), codex.UsageSnapshot{Scope: b, IdentityKnown: true}, "parse"))
	st, err = d.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	assert.True(t, st.IdentityKnown)
	limits, err = VisibleCodexLimits(*st)
	require.NoError(t, err)
	require.Len(t, limits, 1)
	public, err := EvaluateProjection(ProjectionContext{Now: now.Add(26 * time.Minute), FeatureEnabled: true, State: st.State, FetchedAt: st.FetchedAt, IdentityRequired: true, IdentityKnown: true, HasCurrentSample: true}, limits[0], nil)
	require.NoError(t, err)
	require.NotNil(t, public.UnavailableReason)
	assert.Equal(t, "stale", *public.UnavailableReason)
}

func TestDecodeWindowLimits_UnknownProjectionIsStorageError(t *testing.T) {
	for _, text := range []string{"null", "{}", `[{"key":"q","percent":1,"projection":{"state":"unknown"}}]`, `[{"key":"q","percent":-1,"projection":{"state":"safe"}}]`,
		`[{"key":"q","projection":{"state":"safe","rate_per_hour":0}}]`,
		`[{"key":"q","percent":null,"projection":{"state":"safe","rate_per_hour":0}}]`,
		`[{"key":"q","percent":1,"projection":{"state":"safe","rate_per_hour":null}}]`} {
		_, err := DecodeWindowLimits(text)
		require.Error(t, err)
	}
}
