package db

import (
	"database/sql"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestProj01_ProjectTargetsNeverReachNonBoardReaders guards PROJ-01
// (docs/inventory/workbench.md): with one personal and one project target that
// otherwise look identical (active, overdue, digest-sourced, high priority),
// every non-board reader of spec §4.1 in internal/db returns only the personal
// one. Companions in their own packages: TestProj01_DayPlanGatherExcludesProjectTargets
// (internal/dayplan), TestProj01_ExtractSnapshotExcludesProjectTargets and
// TestProj01_NextStepSkipsProjectTarget (internal/targets).
func TestProj01_ProjectTargetsNeverReachNonBoardReaders(t *testing.T) {
	d := openTestDB(t)
	now := time.Now().UTC()
	due := now.Add(-2 * time.Hour).Format("2006-01-02T15:04")

	require.NoError(t, d.UpsertChannel(Channel{ID: "C1", Name: "general", Type: "public", IsMember: true}))
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, message_count)
		VALUES ('C1', ?, ?, 'channel', 'd', 1)`, float64(now.Unix()-3600), float64(now.Unix()))
	require.NoError(t, err)
	digestID, err := res.LastInsertId()
	require.NoError(t, err)
	source := strconv.FormatInt(digestID, 10)

	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "high", Ownership: "mine",
		SourceType: "digest", SourceID: source, DueDate: due})
	require.NoError(t, err)
	pid := newTestWorkbench(t, d)
	onBoard := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "board only")
	// Defense in depth: the predicate, not the project defaults, keeps it out.
	_, err = d.Exec(`UPDATE targets SET source_type = 'digest', source_id = ?, due_date = ?, priority = 'high' WHERE id = ?`,
		source, due, onBoard)
	require.NoError(t, err)

	want := []int{int(personal)}
	ids := func(ts []Target) []int {
		out := make([]int, 0, len(ts))
		for _, tg := range ts {
			out = append(out, tg.ID)
		}
		return out
	}

	t.Run("GetTargets", func(t *testing.T) {
		for _, f := range []TargetFilter{{}, {IncludeDone: true}, {Limit: 100}, {Status: "todo"}} {
			got, err := d.GetTargets(f)
			require.NoError(t, err)
			assert.Equal(t, want, ids(got), "%+v", f)
		}
	})
	t.Run("GetTargetsNeedingNextStep", func(t *testing.T) {
		got, err := d.GetTargetsNeedingNextStep(0)
		require.NoError(t, err)
		assert.Equal(t, want, ids(got))
	})
	t.Run("GetTargetsForBriefing", func(t *testing.T) {
		got, err := d.GetTargetsForBriefing()
		require.NoError(t, err)
		assert.Equal(t, want, ids(got))
	})
	t.Run("GetTargetCounts", func(t *testing.T) {
		active, overdue, err := d.GetTargetCounts()
		require.NoError(t, err)
		assert.Equal(t, 1, active)
		assert.Equal(t, 1, overdue)
	})
	t.Run("ListCatchupTargets", func(t *testing.T) {
		got, err := d.ListCatchupTargets(float64(now.Add(-24*time.Hour).Unix()), float64(now.Add(time.Hour).Unix()), 50)
		require.NoError(t, err)
		require.Len(t, got, 1)
		assert.Equal(t, int(personal), got[0].ID)
	})
	t.Run("ListTargetsForMirror", func(t *testing.T) {
		got, err := d.ListTargetsForMirror()
		require.NoError(t, err)
		require.Len(t, got, 1)
		assert.Equal(t, int(personal), got[0].ID)
	})
	t.Run("GetChannelValueSignals", func(t *testing.T) {
		got, err := d.GetChannelValueSignals()
		require.NoError(t, err)
		assert.Equal(t, 1, got["C1"].TaskCount)
	})
	// Last: it stamps notified_at/updated_at on what it surfaces.
	t.Run("NotifyDueTargets", func(t *testing.T) {
		n, err := d.NotifyDueTargets(now)
		require.NoError(t, err)
		assert.Equal(t, 1, n)
		var surfaced int64
		require.NoError(t, d.QueryRow(`SELECT target_id FROM inbox_items WHERE trigger_type = 'target_due'`).Scan(&surfaced))
		assert.Equal(t, personal, surfaced)
	})
}
