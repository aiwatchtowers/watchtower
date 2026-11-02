package cmd

import (
	"context"
	"errors"
	"log"
	"os"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/planusage"
)

// Both subscription readers share the feature gate, not their timers or failures.
func wirePlanUsage(d *daemon.Daemon, database *db.DB, cfg *config.Config, logger *log.Logger) {
	providers := newPlanProviders(database, cfg, logger)
	d.SetPlanUsage(providers, func() error {
		var errs []error
		for _, p := range providers {
			errs = append(errs, p.Disable(context.Background()))
		}
		return errors.Join(errs...)
	})
}

func planUsageEnabled() (bool, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return false, err
	}
	return cfg.PlanUsage.Enabled, nil
}

func newPlanUsagePoller(database *db.DB, logger *log.Logger) *planusage.Poller {
	return &planusage.Poller{Store: database, Creds: planusage.DefaultCredentialSource(), Client: planusage.NewClient(Version), Now: time.Now, Logger: logger}
}

func newPlanProviders(database *db.DB, cfg *config.Config, logger *log.Logger) planusage.Providers {
	claude := newPlanUsagePoller(database, logger)
	codexPoller := &planusage.CodexPoller{Store: database, Now: time.Now, Read: func(ctx context.Context) (codex.UsageSnapshot, error) {
		latest, err := config.Load(flagConfig)
		if err != nil {
			return codex.UsageSnapshot{}, &planusage.OperationError{Code: "storage", Cause: err}
		}
		return codex.ReadUsage(ctx, codex.FindBinary(latest.CodexPath), os.Environ(), codex.OwnerHome())
	}}
	return planusage.Providers{
		&planusage.Provider{Name: "claude", Workspace: cfg.WorkspaceDir(), Enabled: planUsageEnabled, Logger: logger,
			Poll: func(ctx context.Context) (time.Duration, error) {
				delay, err := claude.PollOnce(ctx)
				if err == nil {
					st, readErr := database.GetPlanUsageStatus()
					if readErr != nil {
						return delay, &planusage.OperationError{Code: "storage", Cause: readErr}
					}
					if st != nil && st.State == "stale" && st.Reason == "token_expired" {
						return delay, &planusage.OperationError{Code: "no_credentials"}
					}
				}
				return delay, err
			}, MarkDisabled: func() error { return planusage.MarkDisabled(database, time.Now()) }},
		&planusage.Provider{Name: "codex", Workspace: cfg.WorkspaceDir(), Enabled: planUsageEnabled, Logger: logger, Poll: codexPoller.PollOnce,
			MarkDisabled: func() error {
				st, err := database.GetCodexPlanUsageStatus()
				if err != nil {
					return err
				}
				if st == nil {
					st = &db.CodexPlanUsageStatus{PlanUsageStatus: db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]", PlotJSON: "{}"}}
				}
				st.State, st.Reason, st.UpdatedAt = "disabled", "", time.Now().UTC()
				return database.UpsertCodexPlanUsageStatus(*st)
			}},
	}
}
