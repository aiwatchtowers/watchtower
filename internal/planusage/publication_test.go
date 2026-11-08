package planusage

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/db"

	"github.com/stretchr/testify/require"
)

func TestPublication_IntegrityAndOrderedGates(t *testing.T) {
	for _, source := range Sources() {
		t.Run(source, func(t *testing.T) {
			database, err := db.Open(":memory:")
			require.NoError(t, err)
			t.Cleanup(func() { require.NoError(t, database.Close()) })
			now := at(10, 0)
			reset := now.Add(time.Hour)
			scope := strings.Repeat("a", 64)
			var good db.PlanUsageStatus
			var write func(db.PlanUsageStatus)
			if source == "codex" {
				require.NoError(t, StoreCodexUsage(database, now.Add(-20*time.Minute), testCodexSnapshot(scope, reset, 20)))
				require.NoError(t, StoreCodexUsage(database, now, testCodexSnapshot(scope, reset, 30)))
				row, err := database.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				good = row.PlanUsageStatus
				write = func(status db.PlanUsageStatus) {
					candidate := *row
					candidate.PlanUsageStatus = status
					require.NoError(t, database.UpsertCodexPlanUsageStatus(candidate))
				}
			} else {
				poller := &Poller{Store: database}
				for i, percent := range []float64{20, 30} {
					require.NoError(t, poller.storeUsage(context.Background(), now.Add(time.Duration(i-1)*20*time.Minute), db.PlanUsageStatus{}, Usage{Limits: []Limit{{Key: "weekly_all", Label: "Weekly", Group: "weekly", Percent: percent, ResetsAt: &reset}}}))
				}
				row, err := database.GetPlanUsageStatus()
				require.NoError(t, err)
				good = *row
				write = func(status db.PlanUsageStatus) { require.NoError(t, database.UpsertPlanUsageStatus(status)) }
			}
			require.Len(t, good.PublicationProof, 64)
			require.Equal(t, publicationDigest(good.LimitsJSON, good.PlotJSON), good.PublicationProof)
			read := func(enabled bool) *PublicStatus {
				status, err := ReadStatus(database, source, enabled, now)
				require.NoError(t, err)
				require.Len(t, status.Limits, 1)
				return status
			}
			require.True(t, read(true).Limits[0].Projection.Drawable)
			var plot Plot
			require.NoError(t, json.Unmarshal([]byte(good.PlotJSON), &plot))
			for _, line := range plot.Limits {
				require.NotNil(t, line)
				require.InDelta(t, 60, line.EndPercent, 1e-8)
				line.EndPercent = 61 // structurally valid; neither language may draw it.
			}
			corrupted, err := json.Marshal(plot)
			require.NoError(t, err)
			for _, tc := range []struct {
				name, reason string
				change       func(*db.PlanUsageStatus)
				enabled      bool
			}{
				{"positive_safe_endpoint", "invalid_projection", func(s *db.PlanUsageStatus) { s.PlotJSON = string(corrupted) }, true},
				{"missing_proof", "invalid_projection", func(s *db.PlanUsageStatus) { s.PublicationProof = "" }, true},
				{"limits_bytes_changed", "invalid_projection", func(s *db.PlanUsageStatus) { s.LimitsJSON += " " }, true},
				{"disabled_precedes_proof", "disabled", func(s *db.PlanUsageStatus) { s.PublicationProof = "" }, false},
				{"error_precedes_proof", "stale", func(s *db.PlanUsageStatus) { s.PublicationProof = ""; s.State = "error" }, true},
				{"legacy_plot", "endpoints_unavailable", func(s *db.PlanUsageStatus) { s.PublicationProof = ""; s.PlotJSON = "{}" }, true},
			} {
				t.Run(tc.name, func(t *testing.T) {
					candidate := good
					tc.change(&candidate)
					write(candidate)
					result := read(tc.enabled).Limits[0].Projection
					require.False(t, result.Drawable)
					require.Nil(t, result.Line)
					require.NotNil(t, result.UnavailableReason)
					require.Equal(t, tc.reason, *result.UnavailableReason)
				})
			}
			write(good)
			if source == "codex" {
				snapshot := testCodexSnapshot(scope, reset, 30)
				require.NoError(t, StoreCodexFailure(database, now, snapshot, "network"))
				retained, err := database.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				require.Equal(t, good.PublicationProof, retained.PublicationProof)
				require.Equal(t, good.PlotJSON, retained.PlotJSON)
				require.NoError(t, StoreCodexFailure(database, now, codex.UsageSnapshot{}, "network"))
				unknown, err := database.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				require.Empty(t, unknown.PublicationProof)
			} else {
				require.NoError(t, MarkDisabled(database, now))
				retained, err := database.GetPlanUsageStatus()
				require.NoError(t, err)
				require.Equal(t, good.PublicationProof, retained.PublicationProof)
				require.Equal(t, good.PlotJSON, retained.PlotJSON)
			}
		})
	}
}

func TestPublication_UTF8FramingVector(t *testing.T) {
	require.Equal(t, "839dd00ccf8e3fc19427bca23689d4c05a51a6fcd1f9511f7372e38cb54b003d",
		publicationDigest(`["квота:é"]`, `{"😀":null}`))
}
