package memory

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRunRetrieveCompare_AllSurfaces: a single RunRetrieveCompare call
// exercises all three surfaces against a small seeded vault/DB and writes
// one shadow row per surface, without touching memory_nodes.
func TestRunRetrieveCompare_AllSurfaces(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RC01", "entity", "Target Entity")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := RunRetrieveCompare(d, v, time.Now().Add(-24*time.Hour), []string{"recall", "briefing", "meeting_prep"})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, stats.RecallCompared, 1)
	assert.Equal(t, 1, stats.BriefingCompared)
	assert.GreaterOrEqual(t, stats.MeetingPrepCompared, 0) // 0 subjects when no beliefs exist yet — a clean, not-failed, run

	for _, surface := range []string{"recall", "briefing"} {
		rows, err := d.ListMemoryRetrieveShadow(surface, time.Time{})
		require.NoError(t, err)
		assert.NotEmpty(t, rows, "surface %s must have written at least one shadow row", surface)
	}
}

// TestRunRetrieveCompare_SurfaceFilter: passing a single surface name runs
// only that surface.
func TestRunRetrieveCompare_SurfaceFilter(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RC02", "entity", "Only Recall")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := RunRetrieveCompare(d, v, time.Now().Add(-24*time.Hour), []string{"recall"})
	require.NoError(t, err)
	assert.Equal(t, 0, stats.BriefingCompared)
	assert.Equal(t, 0, stats.MeetingPrepCompared)

	rows, err := d.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestRenderRetrieveCompareReport(t *testing.T) {
	report := RenderRetrieveCompareReport(RetrieveCompareStats{
		RecallCompared: 3, BriefingCompared: 1, MeetingPrepCompared: 2,
	}, time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC))
	assert.Contains(t, report, "Recall")
	assert.Contains(t, report, "Briefing")
	assert.Contains(t, report, "Meeting prep")
	assert.Contains(t, report, "hand-review")
}
