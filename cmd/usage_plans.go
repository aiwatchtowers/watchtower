package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/planusage"
)

var usagePlansCmd = &cobra.Command{
	Use: "plans", Short: "Claude and Codex subscription limits, history and forecasts",
	// Read-only invocations must never enter the root's schema-upgrade hook.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Args: func(_ *cobra.Command, args []string) error {
		if len(args) != 0 {
			return usageError("usage plans accepts no positional arguments")
		}
		switch flagUsagePlansProvider {
		case "all", "claude", "codex":
		default:
			return usageError("invalid plans provider %q", flagUsagePlansProvider)
		}
		return nil
	},
	RunE:          runUsagePlans,
	SilenceUsage:  true,
	SilenceErrors: true,
}
var flagUsagePlansProvider string
var flagUsagePlansNow, flagUsagePlansJSON bool

func init() {
	usagePlansCmd.Flags().BoolVar(&flagUsagePlansJSON, "json", false, "print JSON")
	usagePlansCmd.Flags().BoolVar(&flagUsagePlansNow, "now", false, "refresh selected subscriptions")
	usagePlansCmd.Flags().StringVar(&flagUsagePlansProvider, "provider", "all", "subscriptions: all, claude or codex")
	usagePlansCmd.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usageError("%v", err) })
	usageCmd.AddCommand(usagePlansCmd)
}

// These two seams allow command tests to prove no fetch/write without spawning
// an installed source CLI. Production always uses the real bounded providers.
var openPlansDB = func(_ context.Context, path string, write bool) (*db.DB, error) {
	if write {
		return db.OpenExistingRW(path, 2*time.Second)
	}
	return db.OpenExisting(path, 2*time.Second)
}
var plansProviders = newPlanProviders

func runUsagePlans(cmd *cobra.Command, _ []string) error {
	ctx, cancel := context.WithCancel(cmd.Context())
	defer cancel()
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	done := make(chan struct{})
	defer close(done)
	var received atomic.Int32
	go func() {
		select {
		case s := <-signals:
			if s == syscall.SIGTERM {
				received.Store(15)
			} else {
				received.Store(2)
			}
			cancel()
		case <-done:
		}
	}()
	cfg, loadErr := workspaceConfigFromFlags()
	enabled := true // A config read failure is storage failure, not feature-off.
	if loadErr == nil {
		enabled = cfg.PlanUsage.Enabled
	}
	var database *db.DB
	var openErr error
	if loadErr != nil {
		openErr = loadErr
	} else {
		database, openErr = openPlansDB(ctx, cfg.DBPath(), flagUsagePlansNow && enabled)
	}
	if database != nil {
		defer database.Close()
	}
	refreshers := map[string]func(context.Context) error{}
	if openErr == nil && flagUsagePlansNow && enabled {
		for _, p := range plansProviders(database, cfg, log.New(io.Discard, "", 0)) {
			refreshers[p.Name] = p.Refresh
		}
	}
	read := func(provider string) (*planusage.PublicStatus, error) {
		if openErr != nil {
			return nil, openErr
		}
		currentEnabled := enabled
		if flagUsagePlansNow {
			var err error
			currentEnabled, err = planUsageEnabled()
			if err != nil {
				return nil, err
			}
		}
		return planusage.ReadStatus(database, provider, currentEnabled, time.Now().UTC())
	}
	if openErr != nil && flagUsagePlansNow && enabled {
		for _, name := range []string{"claude", "codex"} {
			refreshers[name] = func(context.Context) error { return &planusage.OperationError{Code: "storage", Cause: openErr} }
		}
	}
	out := planusage.Collect(ctx, flagUsagePlansProvider, flagUsagePlansNow, enabled, read, refreshers)
	// If cancellation interrupted a provider without its own operation error,
	// do not imply that a refresh completed successfully.
	if received.Load() != 0 && flagUsagePlansNow {
		maskPlansCancellation(&out, openErr != nil)
	}
	if err := json.NewEncoder(cmd.OutOrStdout()).Encode(out); err != nil {
		return fmt.Errorf("writing plans JSON: %w", err)
	}
	code := planusage.ExitCode(out, int(received.Load()))
	if code != 0 {
		return &exitCodeError{code: code, err: errors.New("plan usage operation did not complete")}
	}
	return nil
}

// Preserve completed partial failures when a signal cancels another source.
// A cancelled open/off path never started its refresh and remains unfinished.
func maskPlansCancellation(out *planusage.Envelope, openFailed bool) {
	for i := range out.Providers {
		r := &out.Providers[i]
		if openFailed || r.RefreshOutcome == "disabled" || r.Error != nil && r.Error.Code == "cancelled" {
			r.OK = false
			r.Error = &planusage.PublicError{Code: "cancelled", Message: "Plan usage: cancelled."}
			r.RefreshOutcome = "cancelled"
		}
	}
}
