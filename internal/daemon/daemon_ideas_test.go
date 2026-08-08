package daemon

import (
	"context"
	"log"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/ideas"
)

// TestDaemon_PhaseIdeas_SkipsWhileBackfillLockFresh pins the spec §5
// concurrency guard: phaseIdeas must not run at all — not even far enough to
// advance the throttle timestamp — while a CLI backfill holds a fresh lock,
// so the two never interleave consumption of the same floors.
func TestDaemon_PhaseIdeas_SkipsWhileBackfillLockFresh(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled = true

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-ideas] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-ideas-pipe] ", 0)))

	release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir())
	require.NoError(t, err)
	defer release()

	d.phaseIdeas(context.Background())

	assert.True(t, d.lastIdeas.IsZero(), "phaseIdeas must skip entirely (never even reach the throttle) while a fresh backfill lock exists")
}

// TestDaemon_PhaseIdeas_RunsWhenLockAbsent is the control: with no lock file
// at all, phaseIdeas proceeds past the guard and runs normally (a nil
// generator makes the pipeline itself a clean no-op, so this only proves the
// guard didn't false-positive).
func TestDaemon_PhaseIdeas_RunsWhenLockAbsent(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled = true

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-ideas] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-ideas-pipe] ", 0)))

	d.phaseIdeas(context.Background())

	assert.False(t, d.lastIdeas.IsZero(), "phaseIdeas must run (and advance the throttle) when no backfill lock exists")
}
