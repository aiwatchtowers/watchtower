package cmd

import (
	"bytes"
	"context"
	"io"
	"log"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/builtin"
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

	// The runner executes on the slot executor: a manual run on a no-owner
	// install fails with db.ErrNoOwner (OWNER-02), with no model call.
	run, err := r.RunNow(context.Background(), "morning-brief", automations.BuiltinInput{Only: []string{"brief.compose"}})
	require.NoError(t, err)
	assert.Equal(t, db.RunFailed, run.Status)
	assert.Contains(t, run.Error, db.ErrNoOwner.Error())
	assert.Zero(t, gen.CallCount())
}

// TestWireBuiltins_LogsAnUnusedOwnerCopy: an owner copy that is not a
// regular file is not used, and the daemon's start says so.
func TestWireBuiltins_LogsAnUnusedOwnerCopy(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "acme", Briefing: config.BriefingConfig{Enabled: true}}
	require.NoError(t, os.MkdirAll(builtin.OwnerCopyPath(cfg.WorkspaceDir(), "morning-brief"), 0o755)) // a directory
	database := db.OpenTestDB(t)
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)
	d := daemon.New(cfg)
	d.SetLogger(logger)
	d.SetDB(database)

	wireBuiltins(d, cfg, database, &automationstest.FakeGenerator{}, logger)
	assert.Contains(t, buf.String(), "built-in morning-brief: the edited copy is not a regular file; using the built-in")
}
