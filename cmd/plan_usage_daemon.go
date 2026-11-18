package cmd

import (
	"context"
	"errors"
	"log"
	"os"
	"time"

	"watchtower/internal/claude"
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

// newPlanUsagePoller reads Claude's plan limits from the installed claude's
// get_usage answer; the CLI path is re-read from the config at every poll.
func newPlanUsagePoller(database *db.DB, logger *log.Logger) *planusage.Poller {
	return &planusage.Poller{Store: database, Now: time.Now, Logger: logger, Read: func(ctx context.Context) (claude.UsageSnapshot, error) {
		latest, err := config.Load(flagConfig)
		if err != nil {
			return claude.UsageSnapshot{}, &planusage.OperationError{Code: "storage", Cause: err}
		}
		// The inherited environment with an enriched PATH, as Watchtower's own
		// Claude children, so the gauge describes the account its AI calls
		// use. Resolved on every poll and bounded by ctx: a configured CLI
		// runs no login shell, and a CLI installed later is found.
		bin, env := claude.UsageCommand(ctx, latest.ClaudePath)
		return claude.ReadUsage(ctx, bin, env)
	}}
}

func newPlanProviders(database *db.DB, cfg *config.Config, logger *log.Logger) planusage.Providers {
	claudePoller := newPlanUsagePoller(database, logger)
	codexPoller := &planusage.CodexPoller{Store: database, Now: time.Now, Read: func(ctx context.Context) (codex.UsageSnapshot, error) {
		latest, err := config.Load(flagConfig)
		if err != nil {
			return codex.UsageSnapshot{}, &planusage.OperationError{Code: "storage", Cause: err}
		}
		// App/daemon launches have a minimal PATH; npm's Codex entry point
		// also needs the version manager's node. Runtime discovery must not
		// add a login-shell dependency to an explicitly configured CLI path.
		env := append(os.Environ(), "PATH="+codex.RuntimePATH())
		return codex.ReadUsage(ctx, codex.FindBinary(latest.CodexPath), env, codex.OwnerHome())
	}}
	return planusage.Providers{
		&planusage.Provider{Name: "claude", Workspace: cfg.WorkspaceDir(), Enabled: planUsageEnabled, Logger: logger,
			Poll: claudePoller.PollOnce, MarkDisabled: func(ctx context.Context) error { return planusage.MarkDisabledContext(ctx, database, time.Now()) }},
		&planusage.Provider{Name: "codex", Workspace: cfg.WorkspaceDir(), Enabled: planUsageEnabled, Logger: logger, Poll: codexPoller.PollOnce,
			MarkDisabled: func(ctx context.Context) error {
				st, err := database.GetCodexPlanUsageStatusContext(ctx)
				if err != nil {
					return err
				}
				if st == nil {
					st = &db.CodexPlanUsageStatus{PlanUsageStatus: db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]", PlotJSON: "{}"}}
				}
				st.State, st.Reason, st.UpdatedAt = "disabled", "", time.Now().UTC()
				return database.UpsertCodexPlanUsageStatusContext(ctx, *st)
			}},
	}
}
