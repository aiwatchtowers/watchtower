package daemon

import (
	"context"
	"io"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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

func customTracksPhaseSetup(t *testing.T) (*Daemon, *db.DB) {
	t.Helper()
	database := db.OpenTestDB(t)
	cfg := &config.Config{
		Tracks: config.TracksConfig{Enabled: true},
		Digest: config.DigestConfig{Enabled: true},
	}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(io.Discard, "", 0))
	d.SetDB(database)
	d.SetCustomTracksPipeline(customtracks.New(database, &erroringGenerator{}, "", d.logger))
	return d, database
}

// Once every custom track has spent today's failure budget, the phase must
// write no pipeline_runs row at all — not a 0-item "done" row every cycle
// burying the day's error rows. Two exhausted tracks, so a first-track-only
// check does not pass it.
func TestDaemon_CustomTracks_AllBudgetsSpentWritesNoRun(t *testing.T) {
	d, database := customTracksPhaseSetup(t)
	today := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	for _, instr := range []string{"a", "b"} {
		id, err := database.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: instr, Instruction: instr})
		require.NoError(t, err)
		_, err = database.Exec(`UPDATE tracks SET scan_attempts = 3, scan_attempted_at = ? WHERE id = ?`, today, id)
		require.NoError(t, err)
	}

	d.phaseCustomTrackScan(context.Background())
	d.phaseCustomTrackScan(context.Background())
	assert.Equal(t, 0, customTracksRunCount(t, database))
}

// The degenerate case: no custom track at all is nothing to run either.
func TestDaemon_CustomTracks_NoTracksWritesNoRun(t *testing.T) {
	d, database := customTracksPhaseSetup(t)
	d.phaseCustomTrackScan(context.Background())
	assert.Equal(t, 0, customTracksRunCount(t, database))
}

// A track that is still due gets its tracked run as before.
func TestDaemon_CustomTracks_DueTrackIsTracked(t *testing.T) {
	d, database := customTracksPhaseSetup(t)
	_, err := database.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: "x", Instruction: "x"})
	require.NoError(t, err)

	d.phaseCustomTrackScan(context.Background())
	assert.Equal(t, 1, customTracksRunCount(t, database))
}
