package cmd

import (
	"log"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// wireAutomations attaches the automations scheduler and executor to the
// daemon when automations.enabled is on (spec 2026-10-14 §7, §20 D12); the
// daemon runs them beside the sync loop and wakes them on SIGUSR2. Off, it
// builds nothing (FEAT-01) and logs that.
func wireAutomations(d *daemon.Daemon, cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) {
	if !cfg.Automations.Enabled {
		logger.Println("automations: disabled (automations.enabled=false), scheduler and executor not started")
		return
	}
	d.SetAutomations(newDaemonAutomations(cfg, database, gen, logger))
}

// newDaemonAutomations builds the daemon's scheduler and executor: the
// indexer over the personal folder <WorkspaceDir>/automations (D8, inside the
// workspace data dir — never a TCC-protected folder), the executor on
// buildAutomationRegistry and the daemon's generator, both logging to the
// daemon logger. A run the scheduler queues wakes the executor.
func newDaemonAutomations(cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) (*automations.Scheduler, *automations.Executor) {
	clock := automations.RealClock{}
	exec := automations.NewExecutor(database, automations.Backends{
		DB:        database,
		Generator: gen,
		Registry:  buildAutomationRegistry(cfg, database),
		Clock:     clock,
	}, automations.ExecutorOptions{Logger: logger})
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), clock)
	sched := automations.NewScheduler(database, ix, clock, exec.Wake)
	sched.SetLogger(logger)
	return sched, exec
}
