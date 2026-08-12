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

// TestDaemon_PhaseStreamDigests_RunsIndependentlyOfIdeasEnabled pins the core
// Task 6 contract: with ideas.enabled=false and streams.enabled=true,
// phaseStreamDigests still runs RunStreamDigests — the stage-1 stream
// digests are decoupled from the registry consolidator's own switch.
func TestDaemon_PhaseStreamDigests_RunsIndependentlyOfIdeasEnabled(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Ideas.Enabled = false
	cfg.Streams.Enabled = true
	cfg.Streams.IntervalHours = 6

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	d.phaseStreamDigests(context.Background())

	assert.False(t, d.lastStreams.IsZero(),
		"phaseStreamDigests must run (and advance its own throttle) when streams.enabled=true, regardless of ideas.enabled")

	runs, err := database.GetPipelineRuns(10)
	require.NoError(t, err)
	found := false
	for _, r := range runs {
		if r.Pipeline == "stream-digests" {
			found = true
		}
	}
	assert.True(t, found, "expected a pipeline_runs row labeled stream-digests")
}

// TestDaemon_PhaseStreamDigests_DisabledNeverRuns is the gate control:
// streams.enabled=false must never run the phase, even with a wired
// pipeline.
func TestDaemon_PhaseStreamDigests_DisabledNeverRuns(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = false

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero(), "phaseStreamDigests must not run at all when streams.enabled=false")
}

// TestDaemon_PhaseStreamDigests_SkipsWhileBackfillLockFresh applies the
// phaseIdeas GB7 precedent to the streams phase: a fresh CLI
// `ideas mine --from` backfill lock must make phaseStreamDigests skip
// entirely, not even far enough to advance its own throttle timestamp.
func TestDaemon_PhaseStreamDigests_SkipsWhileBackfillLockFresh(t *testing.T) {
	orch, cfg, wsDir := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = true

	database, err := db.Open(wsDir + "/watchtower.db")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))
	d.SetDB(database)
	d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-streams-pipe] ", 0)))

	release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "CLI backfill")
	require.NoError(t, err)
	defer release()

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero(),
		"phaseStreamDigests must skip entirely — never even run the pipeline — while a fresh CLI backfill lock exists")
}

// TestDaemon_PhaseStreamDigests_NilPipeIsNoop is the nil-pipe guard control:
// with no ideas.Pipeline wired at all (e.g. both ideas.enabled and
// streams.enabled were false at wiring time), the phase must not panic and
// must not advance the throttle.
func TestDaemon_PhaseStreamDigests_NilPipeIsNoop(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Streams.Enabled = true

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-streams] ", 0))

	d.phaseStreamDigests(context.Background())

	assert.True(t, d.lastStreams.IsZero())
}
