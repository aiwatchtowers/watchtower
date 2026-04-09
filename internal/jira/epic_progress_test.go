package jira

import (
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func epicTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func epicTestConfig(enabled bool) *config.Config {
	return &config.Config{
		Jira: config.JiraConfig{
			Enabled: true,
			Features: config.JiraFeatureToggles{
				EpicProgress: enabled,
			},
		},
	}
}

// seedEpicIssue inserts a jira issue with key, epic_key, status_category, and resolved_at.
func seedEpicIssue(t *testing.T, database *db.DB, key, epicKey, statusCategory, resolvedAt string) {
	t.Helper()
	err := database.UpsertJiraIssue(db.JiraIssue{
		Key:            key,
		ID:             key,
		Summary:        "Issue " + key,
		StatusCategory: statusCategory,
		ResolvedAt:     resolvedAt,
		EpicKey:        epicKey,
	})
	require.NoError(t, err)
}

func TestComputeEpicProgress_DisabledFeature(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(false)

	result, err := ComputeEpicProgress(database, cfg, time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestComputeEpicProgress_JiraDisabled(t *testing.T) {
	database := epicTestDB(t)
	cfg := &config.Config{
		Jira: config.JiraConfig{Enabled: false},
	}

	result, err := ComputeEpicProgress(database, cfg, time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestComputeEpicProgress_NoIssues(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)

	result, err := ComputeEpicProgress(database, cfg, time.Now())
	assert.NoError(t, err)
	assert.Nil(t, result)
}

func TestComputeEpicProgress_FilterSmallEpics(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// Epic with only 2 issues — should be filtered out.
	seedEpicIssue(t, database, "PROJ-1", "EPIC-1", "to_do", "")
	seedEpicIssue(t, database, "PROJ-2", "EPIC-1", "done", now.AddDate(0, 0, -3).Format(time.RFC3339))

	result, err := ComputeEpicProgress(database, cfg, now)
	assert.NoError(t, err)
	assert.Empty(t, result, "epics with < 3 issues should be filtered")
}

func TestComputeEpicProgress_BasicProgress(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// Insert the epic issue itself (for name lookup).
	err := database.UpsertJiraIssue(db.JiraIssue{
		Key:     "EPIC-10",
		ID:      "EPIC-10",
		Summary: "Payment Refactor",
	})
	require.NoError(t, err)

	// 5 issues: 2 done (1 this week, 1 two weeks ago), 1 in progress, 2 to do.
	seedEpicIssue(t, database, "P-1", "EPIC-10", "done", now.AddDate(0, 0, -2).Format(time.RFC3339))
	seedEpicIssue(t, database, "P-2", "EPIC-10", "done", now.AddDate(0, 0, -14).Format(time.RFC3339))
	seedEpicIssue(t, database, "P-3", "EPIC-10", "in_progress", "")
	seedEpicIssue(t, database, "P-4", "EPIC-10", "to_do", "")
	seedEpicIssue(t, database, "P-5", "EPIC-10", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)

	ep := result[0]
	assert.Equal(t, "EPIC-10", ep.EpicKey)
	assert.Equal(t, "Payment Refactor", ep.EpicName)
	assert.Equal(t, 5, ep.TotalIssues)
	assert.Equal(t, 2, ep.DoneIssues)
	assert.Equal(t, 1, ep.InProgressIssues)
	assert.InDelta(t, 40.0, ep.ProgressPct, 0.01)    // 2/5 * 100
	assert.InDelta(t, 20.0, ep.WeeklyDeltaPct, 0.01) // 1/5 * 100

	// velocity = 2 resolved in last 28 days / 4 = 0.5
	assert.InDelta(t, 0.5, ep.VelocityPerWeek, 0.01)

	// forecast = (5-2) / 0.5 = 6 weeks
	assert.InDelta(t, 6.0, ep.ForecastWeeks, 0.01)
}

func TestComputeEpicProgress_StatusBadge_OnTrack(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// 4 issues: 2 done this week, 1 done 2 weeks ago, 1 to do.
	// velocity = 3/4 = 0.75, resolvedLastWeek = 2 >= velocity => on_track
	seedEpicIssue(t, database, "A-1", "EPIC-A", "done", now.AddDate(0, 0, -1).Format(time.RFC3339))
	seedEpicIssue(t, database, "A-2", "EPIC-A", "done", now.AddDate(0, 0, -3).Format(time.RFC3339))
	seedEpicIssue(t, database, "A-3", "EPIC-A", "done", now.AddDate(0, 0, -15).Format(time.RFC3339))
	seedEpicIssue(t, database, "A-4", "EPIC-A", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "on_track", result[0].StatusBadge)
}

func TestComputeEpicProgress_StatusBadge_AtRisk(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// 6 issues: 1 done this week, 4 done 2-4 weeks ago, 1 to do.
	// velocity = 5/4 = 1.25, resolvedLastWeek = 1 < 1.25 => at_risk
	seedEpicIssue(t, database, "B-1", "EPIC-B", "done", now.AddDate(0, 0, -2).Format(time.RFC3339))
	seedEpicIssue(t, database, "B-2", "EPIC-B", "done", now.AddDate(0, 0, -10).Format(time.RFC3339))
	seedEpicIssue(t, database, "B-3", "EPIC-B", "done", now.AddDate(0, 0, -18).Format(time.RFC3339))
	seedEpicIssue(t, database, "B-4", "EPIC-B", "done", now.AddDate(0, 0, -22).Format(time.RFC3339))
	seedEpicIssue(t, database, "B-5", "EPIC-B", "done", now.AddDate(0, 0, -25).Format(time.RFC3339))
	seedEpicIssue(t, database, "B-6", "EPIC-B", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "at_risk", result[0].StatusBadge)
}

func TestComputeEpicProgress_StatusBadge_Behind(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// 3 issues: none done => velocity 0 => behind
	seedEpicIssue(t, database, "C-1", "EPIC-C", "to_do", "")
	seedEpicIssue(t, database, "C-2", "EPIC-C", "in_progress", "")
	seedEpicIssue(t, database, "C-3", "EPIC-C", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "behind", result[0].StatusBadge)
	assert.InDelta(t, 999.0, result[0].ForecastWeeks, 0.01)
}

func TestComputeEpicProgress_CompletedEpic(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// All 3 done => on_track, forecast 0
	seedEpicIssue(t, database, "D-1", "EPIC-D", "done", now.AddDate(0, 0, -1).Format(time.RFC3339))
	seedEpicIssue(t, database, "D-2", "EPIC-D", "done", now.AddDate(0, 0, -5).Format(time.RFC3339))
	seedEpicIssue(t, database, "D-3", "EPIC-D", "done", now.AddDate(0, 0, -10).Format(time.RFC3339))

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "on_track", result[0].StatusBadge)
	assert.InDelta(t, 100.0, result[0].ProgressPct, 0.01)
	assert.InDelta(t, 0.0, result[0].ForecastWeeks, 0.01)
}

func TestComputeEpicProgress_SortOrder(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// EPIC-X: behind (0 velocity)
	seedEpicIssue(t, database, "X-1", "EPIC-X", "to_do", "")
	seedEpicIssue(t, database, "X-2", "EPIC-X", "to_do", "")
	seedEpicIssue(t, database, "X-3", "EPIC-X", "in_progress", "")

	// EPIC-Y: on_track (good velocity, all recent)
	seedEpicIssue(t, database, "Y-1", "EPIC-Y", "done", now.AddDate(0, 0, -1).Format(time.RFC3339))
	seedEpicIssue(t, database, "Y-2", "EPIC-Y", "done", now.AddDate(0, 0, -3).Format(time.RFC3339))
	seedEpicIssue(t, database, "Y-3", "EPIC-Y", "done", now.AddDate(0, 0, -5).Format(time.RFC3339))
	seedEpicIssue(t, database, "Y-4", "EPIC-Y", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 2)

	// behind first, on_track second
	assert.Equal(t, "EPIC-X", result[0].EpicKey)
	assert.Equal(t, "behind", result[0].StatusBadge)
	assert.Equal(t, "EPIC-Y", result[1].EpicKey)
	assert.Equal(t, "on_track", result[1].StatusBadge)
}

func TestComputeEpicProgress_ForecastZeroVelocity(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// All resolved > 28 days ago => velocity 0 for the 4-week window, but done count = 1
	seedEpicIssue(t, database, "F-1", "EPIC-F", "done", now.AddDate(0, 0, -60).Format(time.RFC3339))
	seedEpicIssue(t, database, "F-2", "EPIC-F", "to_do", "")
	seedEpicIssue(t, database, "F-3", "EPIC-F", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.InDelta(t, 999.0, result[0].ForecastWeeks, 0.01)
	assert.InDelta(t, 0.0, result[0].VelocityPerWeek, 0.01)
}

func TestComputeEpicProgress_MultipleEpicsMixed(t *testing.T) {
	database := epicTestDB(t)
	cfg := epicTestConfig(true)
	now := time.Date(2026, 4, 9, 12, 0, 0, 0, time.UTC)

	// EPIC-M1: 3 issues, 1 done (old) => behind (0 resolved this week, velocity > 0 from 4w)
	// Actually velocity from 4w: resolved_at was 20 days ago, within 28 days
	seedEpicIssue(t, database, "M1-1", "EPIC-M1", "done", now.AddDate(0, 0, -20).Format(time.RFC3339))
	seedEpicIssue(t, database, "M1-2", "EPIC-M1", "to_do", "")
	seedEpicIssue(t, database, "M1-3", "EPIC-M1", "to_do", "")

	// EPIC-M2: 2 issues only => filtered
	seedEpicIssue(t, database, "M2-1", "EPIC-M2", "done", now.AddDate(0, 0, -1).Format(time.RFC3339))
	seedEpicIssue(t, database, "M2-2", "EPIC-M2", "to_do", "")

	result, err := ComputeEpicProgress(database, cfg, now)
	require.NoError(t, err)
	require.Len(t, result, 1, "only EPIC-M1 should pass the filter")
	assert.Equal(t, "EPIC-M1", result[0].EpicKey)
	assert.Equal(t, "behind", result[0].StatusBadge) // resolvedLastWeek=0
}
