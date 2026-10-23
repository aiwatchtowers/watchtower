package daemon

import (
	"context"
	"io"
	"log"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
)

func customTracksRunCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'custom_tracks'`).Scan(&n))
	return n
}

// customTracksPhaseSetup is a daemon with tracks and digests on, an owner,
// the custom-track pipeline over a failing model and the built-ins wired;
// recipe says whether the custom-tracks move is done (the watch recipes
// only) or not (the legacy scan of unbound tracks, then the recipes).
func customTracksPhaseSetup(t *testing.T, recipe bool) (*Daemon, *db.DB, *config.Config) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	database := db.OpenTestDB(t)
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, err)
	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Tracks:          config.TracksConfig{Enabled: true},
		Digest:          config.DigestConfig{Enabled: true},
	}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetCustomTracksPipeline(customtracks.New(database, &erroringGenerator{}, "", d.logger))
	wireTestBuiltins(t, d, database, cfg, automations.RealClock{})
	d.builtinActive[customTracksID] = recipe
	return d, database, cfg
}

// seedScanActivity adds a channel digest created a minute ago: activity the
// watch gate sees.
func seedScanActivity(t *testing.T, database *db.DB) {
	t.Helper()
	id, err := database.UpsertDigest(db.Digest{ChannelID: "C1", Type: "channel", PeriodFrom: 1, PeriodTo: 2,
		Summary: "launch talk", Topics: `[]`, Decisions: `[]`, ActionItems: `[]`, MessageCount: 3})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE digests SET created_at = ? WHERE id = ?`,
		time.Now().Add(-time.Minute).UTC().Format("2006-01-02T15:04:05Z"), id)
	require.NoError(t, err)
}

func spendTodaysBudget(t *testing.T, database *db.DB, id int) {
	t.Helper()
	today := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	_, err := database.Exec(`UPDATE tracks SET scan_attempts = 3, scan_attempted_at = ? WHERE id = ?`, today, id)
	require.NoError(t, err)
}

// Once every custom track has spent today's failure budget, the phase must
// write no pipeline_runs row at all — not a 0-item "done" row every cycle
// burying the day's error rows. Two exhausted tracks, so a first-track-only
// check does not pass it.
func TestDaemon_CustomTracks_AllBudgetsSpentWritesNoRun(t *testing.T) {
	d, database, _ := customTracksPhaseSetup(t, false)
	for _, instr := range []string{"a", "b"} {
		id, err := database.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: instr, Instruction: instr})
		require.NoError(t, err)
		spendTodaysBudget(t, database, int(id))
	}

	d.phaseWatchSlot(context.Background())
	d.phaseWatchSlot(context.Background())
	assert.Equal(t, 0, customTracksRunCount(t, database))
}

// The recipe twin: watch recipes whose tracks have all spent today's budget
// write no automation run (nor a pipeline_runs row), even with activity.
func TestDaemon_CustomTracks_AllBudgetsSpentWritesNoRun_Recipe(t *testing.T) {
	d, database, cfg := customTracksPhaseSetup(t, true)
	seedScanActivity(t, database)
	owner, err := database.ResolveOwner()
	require.NoError(t, err)
	for _, slug := range []string{"a", "b"} {
		a := addWatchRecipe(t, database, cfg, slug, "watch "+slug)
		id, err := database.EnsureWatchTrack(a.ID, owner.ID, a.Name, "watch "+slug)
		require.NoError(t, err)
		spendTodaysBudget(t, database, id)
	}

	d.phaseWatchSlot(context.Background())
	d.phaseWatchSlot(context.Background())
	assertNoPipelineOrAutomationRuns(t, cfg, database)
}

// The degenerate case: no custom track at all is nothing to run either.
func TestDaemon_CustomTracks_NoTracksWritesNoRun(t *testing.T) {
	d, database, _ := customTracksPhaseSetup(t, false)
	d.phaseWatchSlot(context.Background())
	assert.Equal(t, 0, customTracksRunCount(t, database))
}

// The recipe twin: no watch recipe is nothing to run.
func TestDaemon_CustomTracks_NoTracksWritesNoRun_Recipe(t *testing.T) {
	d, database, cfg := customTracksPhaseSetup(t, true)
	seedScanActivity(t, database)
	d.phaseWatchSlot(context.Background())
	assertNoPipelineOrAutomationRuns(t, cfg, database)
}

// A track that is still due gets its tracked run as before.
func TestDaemon_CustomTracks_DueTrackIsTracked(t *testing.T) {
	d, database, _ := customTracksPhaseSetup(t, false)
	_, err := database.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: "x", Instruction: "x"})
	require.NoError(t, err)

	d.phaseWatchSlot(context.Background())
	assert.Equal(t, 1, customTracksRunCount(t, database))
}

// The recipe twin: a due watch recipe gets one sync automation run (its
// history), and no custom_tracks pipeline_runs row.
func TestDaemon_CustomTracks_DueTrackIsTracked_Recipe(t *testing.T) {
	d, database, cfg := customTracksPhaseSetup(t, true)
	seedScanActivity(t, database)
	a := addWatchRecipe(t, database, cfg, "x", "watch x")

	d.phaseWatchSlot(context.Background())
	runs, err := database.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerSync, runs[0].Trigger)
	assert.Equal(t, 0, customTracksRunCount(t, database))
}
