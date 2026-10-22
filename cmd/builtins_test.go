package cmd

import (
	"context"
	"io"
	"log"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
)

// TestWireBuiltins_SlotExecutorHasMainBackends: the slot executor runs on
// the main executor's backends (the read tools of automationBackends) plus
// the daemon's primitives and the shipped prompts, and the wiring stands on
// its own — no wireAutomations, as when the owner-recipe upgrade step failed
// (automationsOK == false).
func TestWireBuiltins_SlotExecutorHasMainBackends(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "acme",
		Briefing: config.BriefingConfig{Enabled: true}, DayPlan: config.DayPlanConfig{Enabled: true}}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	database := db.OpenTestDB(t)
	gen := &automationstest.FakeGenerator{}
	logger := log.New(io.Discard, "", 0)
	d := daemon.New(cfg)
	d.SetLogger(logger)
	d.SetDB(database)
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, logger))
	d.SetDayPlanPipeline(dayplan.New(database, cfg, gen, logger))

	b := slotBackends(d, cfg, database, gen)
	require.NotNil(t, b.Registry)
	_, ok := b.Registry.Get("list_targets")
	assert.True(t, ok, "the slot executor has automationBackends' read tools")
	for _, name := range automations.BuiltinPrimitiveNames {
		assert.NotNil(t, b.Primitives[name], name)
	}
	require.NotNil(t, b.DefaultPrompt)
	_, err := b.DefaultPrompt("morning-brief", "brief", "")
	require.NoError(t, err)

	r := wireBuiltins(d, cfg, database, gen, logger)
	require.NotNil(t, r)
	a, err := database.GetBuiltinAutomation("morning-brief")
	require.NoError(t, err)
	assert.True(t, a.Confirmed(), "the shipped text is confirmed by the sync")

	// The runner executes on the slot executor: a no-owner install's brief
	// is a benign skip in the daemon, so the run succeeds with no model call.
	run, err := r.RunNow(context.Background(), "morning-brief", automations.BuiltinInput{Only: []string{"brief.compose"}})
	require.NoError(t, err)
	assert.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Zero(t, gen.CallCount())
}
