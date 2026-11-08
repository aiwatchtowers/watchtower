package planusage

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// This bundle is test-only: unlike the public envelope, its DB fixture has a
// synthetic hashed scope so Swift can exercise the real scoped query path.
type pipelineSample struct {
	Scope    string  `json:"scope"`
	Key      string  `json:"limit_key"`
	TakenAt  string  `json:"taken_at"`
	Percent  float64 `json:"percent"`
	ResetsAt string  `json:"resets_at"`
}

func TestCodexPipeline_RawRPCToSharedDesktopFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "codex_pipeline_response.json"))
	require.NoError(t, err)
	var source struct {
		Before json.RawMessage `json:"before"`
		After  json.RawMessage `json:"after"`
	}
	require.NoError(t, json.Unmarshal(raw, &source))
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, database.Close()) })
	bin, err := os.Executable()
	require.NoError(t, err)
	start := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	var snapshot codex.UsageSnapshot
	for i, response := range []json.RawMessage{source.Before, source.After} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		snapshot, err = codex.ReadUsage(ctx, bin,
			append(os.Environ(), "WATCHTOWER_TEST_CODEX_USAGE=1", "WATCHTOWER_TEST_CODEX_LIMITS="+string(response)),
			"pipeline-fixture-home")
		cancel()
		require.NoError(t, err)
		require.NoError(t, StoreCodexUsage(database, start.Add(time.Duration(i)*20*time.Minute), snapshot))
	}
	now := start.Add(20 * time.Minute)
	row, err := database.GetCodexPlanUsageStatus()
	require.NoError(t, err)
	require.NotNil(t, row)
	limits, err := VisibleCodexLimits(*row)
	require.NoError(t, err)
	require.Len(t, limits, 2)
	weekly := limits[0]
	require.NotNil(t, weekly.ResetsAt)
	// These rows must not alter either language's published history: another
	// account, a future/unpublished observation, and a different reset window.
	for _, sample := range []pipelineSample{
		{strings.Repeat("b", 64), weekly.Key, start.Add(10 * time.Minute).Format(time.RFC3339), 99, weekly.ResetsAt.Format(time.RFC3339)},
		{snapshot.Scope, weekly.Key, now.Add(time.Minute).Format(time.RFC3339), 90, weekly.ResetsAt.Format(time.RFC3339)},
		{snapshot.Scope, weekly.Key, start.Add(10 * time.Minute).Format(time.RFC3339), 99, weekly.ResetsAt.Add(61 * time.Second).Format(time.RFC3339)},
	} {
		_, err := database.Exec(`INSERT INTO codex_plan_usage_samples (scope, limit_key, taken_at, percent, resets_at) VALUES (?, ?, ?, ?, ?)`,
			sample.Scope, sample.Key, sample.TakenAt, sample.Percent, sample.ResetsAt)
		require.NoError(t, err)
	}
	public, err := ReadStatus(database, "codex", true, now)
	require.NoError(t, err)
	require.NotNil(t, public)
	require.Len(t, public.Limits, 2)
	assert.Equal(t, "will_hit", public.Limits[0].Projection.State)
	assert.Equal(t, "safe", public.Limits[1].Projection.State)
	for _, limit := range public.Limits {
		require.True(t, limit.Projection.Drawable)
		require.NotNil(t, limit.Projection.Line)
		history, err := database.CodexPlanUsageHistory(snapshot.Scope, limit.Key, start, now, *limit.ResetsAt)
		require.NoError(t, err)
		require.Len(t, history, 2)
	}
	envelope := Collect(context.Background(), "codex", false, true, func(provider string) (*PublicStatus, error) {
		return ReadStatus(database, provider, true, now)
	}, nil)
	assert.Equal(t, 0, ExitCode(envelope, 0))
	var samples []pipelineSample
	rows, err := database.Query(`SELECT scope, limit_key, taken_at, percent, resets_at FROM codex_plan_usage_samples ORDER BY scope, limit_key, taken_at`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var sample pipelineSample
		require.NoError(t, rows.Scan(&sample.Scope, &sample.Key, &sample.TakenAt, &sample.Percent, &sample.ResetsAt))
		samples = append(samples, sample)
	}
	require.NoError(t, rows.Err())
	bundle := map[string]any{
		"schema_version": 1, "now": now, "scope": snapshot.Scope,
		"status": map[string]any{
			"state": row.State, "reason": row.Reason, "plan": row.Plan, "fetched_at": row.FetchedAt,
			"updated_at": row.UpdatedAt, "last_error": row.LastError, "identity_known": row.IdentityKnown,
			"ordinary_usage_allowed": row.OrdinaryUsageAllowed,
			"limits":                 json.RawMessage(row.LimitsJSON), "plot_json": json.RawMessage(row.PlotJSON),
			"limits_json": row.LimitsJSON, "plot_json_raw": row.PlotJSON, "publication_proof": row.PublicationProof,
		},
		"samples": samples, "envelope": envelope,
	}
	encoded, err := json.MarshalIndent(bundle, "", "  ")
	require.NoError(t, err)
	assert.NotContains(t, string(encoded), "fixture-account-one")
	assert.NotContains(t, string(encoded), "identity-canary")
	publicJSON, err := json.Marshal(envelope)
	require.NoError(t, err)
	assert.NotContains(t, string(publicJSON), snapshot.Scope)
	path := filepath.Join("testdata", "codex_pipeline_v1.json")
	if *updatePlansGoldens {
		require.NoError(t, os.WriteFile(path, append(encoded, '\n'), 0o644))
	}
	expected, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.JSONEq(t, string(expected), string(encoded), "Swift consumes this exact real-reader/store/publication bundle")
}
