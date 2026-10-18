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
// daemon (spec 2026-10-14 §7; always on since board #671 — a recipe runs only
// after the owner confirms and enables it); the daemon runs them beside the
// sync loop and wakes them on SIGUSR2. With them comes the event bus (§8) the
// sync phases publish into; a run its per-cycle flush queues wakes the
// executor. runSyncDaemon skips it only when the one-time upgrade step failed
// (pauseAutomationsTurnedOff).
func wireAutomations(d *daemon.Daemon, cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) {
	sched, exec := newDaemonAutomations(cfg, database, gen, logger)
	d.SetAutomations(sched, exec)
	d.SetAutomationEvents(automations.NewBus(database, automations.RealClock{}, exec.Wake, logger))
}

// newDaemonAutomations builds the daemon's scheduler and executor: the
// indexer over the personal folder <WorkspaceDir>/automations (D8, inside the
// workspace data dir — never a TCC-protected folder) and, each tick, every
// workbench folder that is not privacy-protected (the scheduler never
// touches a protected one), the executor on
// automationBackends with the daemon's generator, both logging to the
// daemon logger. A run the scheduler queues wakes the executor.
func newDaemonAutomations(cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) (*automations.Scheduler, *automations.Executor) {
	clock := automations.RealClock{}
	exec := automations.NewExecutor(database, automationBackends(cfg, database, gen), automations.ExecutorOptions{Logger: logger})
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), clock)
	sched := automations.NewScheduler(database, ix, clock, exec.Wake)
	sched.SetLogger(logger)
	return sched, exec
}
