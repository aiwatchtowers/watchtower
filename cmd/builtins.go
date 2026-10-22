package cmd

import (
	"context"
	"log"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// wireBuiltins wires the built-in automations into the daemon (spec
// 2026-10-22 §5.1): a slot executor of its own — never Run, it executes the
// slot runs inline — over the main executor's backends (so slot recipes have
// the read tools) plus the daemon's primitives and the shipped prompts;
// every built-in's row synced; the runner handed to the daemon. It runs
// whatever the owner-recipe upgrade step decided (automationsOK): a failed
// step never stops the brief. A built-in whose sync failed keeps its legacy
// phases this run.
//
// The runner and the daemon share cfg: the daemon never reloads its config
// in process (the app restarts it after a settings change), so the runner's
// on/off and hour reads are the daemon's.
func wireBuiltins(d *daemon.Daemon, cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) *builtin.Runner {
	exec := automations.NewExecutor(database, slotBackends(d, cfg, database, gen), automations.ExecutorOptions{Logger: logger})
	gates := map[string]builtin.Gate{"morning-brief": d.MorningBriefGate()}
	runner := builtin.NewRunner(database, exec, gates, cfg, automations.RealClock{}, logger)

	active := map[string]bool{}
	now := time.Now()
	for _, e := range builtin.All() {
		if _, err := builtin.SyncOne(context.Background(), database, cfg.WorkspaceDir(), cfg, e.ID, now); err != nil {
			logger.Printf("built-in %s: sync failed, its legacy phases run: %v", e.ID, err)
			continue
		}
		if note := builtin.OwnerCopyNote(cfg.WorkspaceDir(), e.ID); note != "" {
			logger.Printf("built-in %s: %s", e.ID, note)
		}
		active[e.ID] = true
	}
	// Task 8 seam: upgradeBuiltins(…) runs here, between the sync and
	// SetBuiltins, and narrows active.
	d.SetBuiltins(runner, active)
	return runner
}

// slotBackends are the slot executor's backends: automationBackends with the
// daemon's built-in primitives and the shipped default prompts.
func slotBackends(d *daemon.Daemon, cfg *config.Config, database *db.DB, gen digest.Generator) automations.Backends {
	b := automationBackends(cfg, database, gen)
	b.Primitives = d.BuiltinPrimitives()
	b.DefaultPrompt = builtin.DefaultPromptFunc
	return b
}
