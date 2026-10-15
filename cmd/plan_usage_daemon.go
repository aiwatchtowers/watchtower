package cmd

import (
	"log"
	"time"

	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/planusage"
)

// wirePlanUsage attaches the Claude plan limits poller (spec 2026-10-15); the
// daemon runs it when plan_usage.enabled is on and marks it disabled otherwise.
func wirePlanUsage(d *daemon.Daemon, database *db.DB, logger *log.Logger) {
	d.SetPlanUsage(newPlanUsagePoller(database, logger), func() error {
		return planusage.MarkDisabled(database, time.Now())
	})
}

func newPlanUsagePoller(database *db.DB, logger *log.Logger) *planusage.Poller {
	return &planusage.Poller{
		Store:  database,
		Creds:  planusage.DefaultCredentialSource(),
		Client: planusage.NewClient(Version),
		Now:    time.Now,
		Logger: logger,
	}
}
