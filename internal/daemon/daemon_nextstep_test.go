package daemon

import (
	"context"
	"log"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/targets"
)

// alwaysFailGenerator is a digest.Generator that always errors — used to
// drive phaseNextStep's "every selected target failed" branch without
// depending on any particular next-step JSON shape.
type alwaysFailGenerator struct{}

func (alwaysFailGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	return "", nil, "", assert.AnError
}

// TestDaemon_PhaseNextStep_AllFailedIsDistinguishableFromNothingToDo pins the
// pipeline_runs visibility fix (verify-backoff.md §6): before this change, a
// cycle where every selected target failed and a cycle where nothing needed a
// refresh both recorded status="done", items_found=0 — the owner could not
// tell "gave up" from "nothing to do". Now a cycle with selected-but-failed
// targets must surface as status="error" with a message naming the count.
func TestDaemon_PhaseNextStep_AllFailedIsDistinguishableFromNothingToDo(t *testing.T) {
	database := db.OpenTestDB(t)

	_, err := database.CreateTarget(db.Target{
		Text: "will fail", Status: "todo", Ownership: "mine", Priority: "medium",
		SourceType: "manual", PeriodStart: "2026-07-01",
	})
	require.NoError(t, err)

	cfg := &config.Config{Targets: config.TargetsConfig{NextStep: config.TargetsNextStepConfig{Enabled: true}}}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(os.Stderr, "[test] ", 0))
	d.SetDB(database)
	d.SetNextStepPipeline(targets.New(database, &cfg.Targets, alwaysFailGenerator{}, nil, "", nil))

	d.phaseNextStep(context.Background())

	runs, err := database.GetPipelineRuns(10)
	require.NoError(t, err)
	require.Len(t, runs, 1, "expected exactly one next_step pipeline_runs row")
	run := runs[0]
	assert.Equal(t, "next_step", run.Pipeline)
	assert.Equal(t, "error", run.Status, "an all-failed cycle must not read as status=done")
	assert.Equal(t, 0, run.ItemsFound)
	assert.Contains(t, run.ErrorMsg, "1", "error message should name the attempted count")
}

// TestDaemon_PhaseNextStep_NothingToDoStaysClean is the paired negative case:
// zero eligible targets must still record a clean "done, 0" run, not the
// synthetic failure message — the fix must only fire when something was
// actually attempted and failed.
func TestDaemon_PhaseNextStep_NothingToDoStaysClean(t *testing.T) {
	database := db.OpenTestDB(t)

	cfg := &config.Config{Targets: config.TargetsConfig{NextStep: config.TargetsNextStepConfig{Enabled: true}}}
	d := newDaemon(nil, cfg)
	d.SetLogger(log.New(os.Stderr, "[test] ", 0))
	d.SetDB(database)
	d.SetNextStepPipeline(targets.New(database, &cfg.Targets, alwaysFailGenerator{}, nil, "", nil))

	d.phaseNextStep(context.Background())

	runs, err := database.GetPipelineRuns(10)
	require.NoError(t, err)
	require.Len(t, runs, 1)
	run := runs[0]
	assert.Equal(t, "done", run.Status, "a no-op cycle must stay status=done")
	assert.Empty(t, run.ErrorMsg)
	assert.Equal(t, 0, run.ItemsFound)
}
