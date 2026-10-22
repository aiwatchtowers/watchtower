package cmd

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// wireBuiltins wires the built-in automations into the daemon (spec
// 2026-10-22 §5.1): a slot executor of its own — never Run, it executes the
// slot runs inline — over the main executor's backends (so slot recipes have
// the read tools) plus the daemon's primitives and the shipped prompts;
// every built-in's row synced and moved from its old pipeline settings
// (upgradeBuiltins); the runner handed to the daemon. It runs
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
	// The one-time settings move: a built-in whose move failed keeps its
	// legacy phases this run.
	for id, moved := range upgradeBuiltins(cfg, database, now, logger) {
		active[id] = active[id] && moved
	}
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

// morningBriefID is the Morning brief built-in's id.
const morningBriefID = "morning-brief"

// The CLI generate commands' refusals, printed on stderr as they are (the
// Desktop's inline Regenerate row shows that text).
const (
	msgMorningBriefUnconfirmed = "Morning brief: your edited copy is not confirmed yet — confirm it in Automations → Built in"
	msgMorningBriefRunning     = "Morning brief is running now — try again in a minute"
	msgMorningBriefQueued      = "Morning brief is already queued for the next sync"
	msgMorningBriefCopyError   = "Morning brief: your edited copy has an error — fix it in Automations → Built in"
)

// cliBuiltinGenerator is the generator of the CLI's built-in runs (`briefing
// generate`, `day-plan generate`); tests swap it.
var cliBuiltinGenerator = cliPooledGenerator

// builtinLookup is builtin.Lookup behind a test seam (`automations run` of a
// built-in without Run Now).
var builtinLookup = builtin.Lookup

// builtinRunSignal wakes the daemon for a queued built-in run: a sync now,
// since a built-in runs at its slot in the sync cycle. Tests swap it.
var builtinRunSignal = signalSyncNow

// newCLIBuiltinRunner is the built-ins' runner of a CLI command: an executor
// of its own over automationBackends (the read tools an owner copy may use,
// as the daemon's slot executor has) with the Morning brief primitives over
// this process's briefing and day-plan pipelines — no gates, no attempt
// budget, no pipeline_runs rows, as the CLI commands always ran — and the
// shipped prompts. It has no gates: the CLI only calls RunNow.
func newCLIBuiltinRunner(cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) *builtin.Runner {
	brief := briefing.New(database, cfg, gen, logger)
	brief.SetPromptStore(prompts.New(database, nil))
	plan := dayplan.New(database, cfg, gen, logger)
	plan.SetPromptStore(prompts.New(database, nil))
	b := automationBackends(cfg, database, gen)
	b.Primitives = builtin.MorningBriefPrimitives(brief, plan, builtin.MorningBriefHooks{
		Owner: database.RequireOwner,
		Items: func(planID int64) (int, error) {
			items, err := database.GetDayPlanItems(planID)
			return len(items), err
		},
	})
	b.DefaultPrompt = builtin.DefaultPromptFunc
	exec := automations.NewExecutor(database, b, automations.ExecutorOptions{Logger: logger})
	return builtin.NewRunner(database, exec, nil, cfg, automations.RealClock{}, logger)
}

// runMorningBriefNow runs the Morning brief's primitives in "in" now, inline
// in this process, through the built-in's current recipe (the shipped text or
// the owner's confirmed copy). The row is synced first (a database the daemon
// never synced has none) with cfg as loaded, so the row keeps mirroring the
// features' real on/off state; the pipelines then run with both features
// forced on, so the commands work with the feature off, as they always did.
//
// SIGINT/SIGTERM end the run here. A CLI killed outright (SIGKILL) leaves its
// run running; the built-ins' runner ends such a run once it is past its
// deadline (db.MarkStaleBuiltinRuns), before the next slot or Run Now.
func runMorningBriefNow(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger, in automations.BuiltinInput) error {
	if ctx == nil {
		ctx = context.Background()
	}
	row, err := builtin.SyncOne(ctx, database, cfg.WorkspaceDir(), cfg, morningBriefID, time.Now())
	if err != nil {
		return err
	}
	if row.ParseError != "" {
		return errors.New(msgMorningBriefCopyError) //nolint:staticcheck // ST1005: the text the Desktop shows
	}
	pipeCfg := *cfg
	pipeCfg.Briefing.Enabled, pipeCfg.DayPlan.Enabled = true, true
	gen, closeGen := cliBuiltinGenerator(&pipeCfg)
	defer closeGen()
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		stop() // the first signal ends the run; a second one quits at once
	}()
	run, err := newCLIBuiltinRunner(&pipeCfg, database, gen, logger).RunNow(ctx, morningBriefID, in)
	switch {
	case errors.Is(err, builtin.ErrRunNowQueued):
		return errors.New(msgMorningBriefQueued) //nolint:staticcheck // ST1005: the text the Desktop shows
	case errors.Is(err, automations.ErrNotRunnable):
		return errors.New(msgMorningBriefUnconfirmed) //nolint:staticcheck // ST1005: the pinned text the Desktop shows
	case errors.Is(err, automations.ErrRunNotClaimed):
		return errors.New(msgMorningBriefRunning) //nolint:staticcheck // ST1005: the pinned text the Desktop shows
	case err != nil:
		return err
	}
	if run.Status != db.RunSucceeded {
		return fmt.Errorf("Morning brief run #%d %s: %s", run.ID, run.Status, run.Error) //nolint:staticcheck // ST1005: the built-in's name
	}
	return nil
}
