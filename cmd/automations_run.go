package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// automationsDryRunGenerator is the generator a CLI dry run's llm() calls
// use — the bounded CLI generator (H8 wall-clock cap). Tests swap it.
var automationsDryRunGenerator = func(cfg *config.Config) digest.Generator {
	return cliBoundedGenerator(cfg)
}

// dryRunUnconfirmedHint ends the refusal of a dry run of an unconfirmed
// recipe under an AI agent's markers (spec §20.1 D16, ask #271).
const dryRunUnconfirmedHint = "only the owner can dry-run a recipe that is not confirmed yet; use Dry run on its card in Automations"

// runJSON is `run --json` — the pinned key set of plan Task 12.
type runJSON struct {
	RunID         int64 `json:"run_id"`
	Coalesced     bool  `json:"coalesced"`
	DaemonRunning bool  `json:"daemon_running"`
}

// dryRunJSON is `dry-run --json` — the pinned key set of plan Task 12; the
// Desktop reads the steps from the database by run_id.
type dryRunJSON struct {
	RunID        int64  `json:"run_id"`
	Status       string `json:"status"`
	Error        string `json:"error"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
}

// notRunnableReason says why a is not runnable ("" when it is).
func notRunnableReason(a *db.Automation) string {
	switch {
	case a.ParseError != "":
		return "its recipe does not parse: " + a.ParseError
	case a.RemovedAt != nil:
		return "its recipe file is gone"
	case !automationConfirmed(a):
		return "it needs your confirmation (Automations, or `watchtower automations confirm`)"
	case !a.Enabled:
		return "it is disabled (`watchtower automations enable`)"
	}
	return ""
}

// runAutomationsRun only queues a run (AUTO-09) and wakes the daemon; the
// daemon's executor runs it. A button automation's run is trigger='button',
// any other (and every --rerun-of) trigger='manual' (spec §7.1).
func runAutomationsRun(cmd *cobra.Command, args []string) error {
	id, err := parseAutomationID("automation id", args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := database.GetAutomation(id)
	if err != nil {
		return err
	}
	if reason := notRunnableReason(a); reason != "" {
		return fmt.Errorf("automation %d cannot run: %s", id, reason)
	}
	trigger, err := runTrigger(database, a, autoFlags.RerunOf)
	if err != nil {
		return err
	}
	runID, coalesced, err := database.EnqueueAutomationRun(db.EnqueueRequest{
		AutomationID: id, Trigger: trigger, RerunOf: autoFlags.RerunOf, Now: time.Now(),
	})
	if err != nil {
		return err
	}
	out := runJSON{RunID: runID, Coalesced: coalesced}
	out.DaemonRunning, err = wakeAutomations(cfg)
	if err != nil {
		// The run is queued either way; the daemon picks it up on its next poll.
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: run #%d is queued, but the daemon was not woken: %v\n", runID, err)
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	if coalesced {
		fmt.Fprintf(w, "Run #%d was already queued.\n", runID)
	} else {
		fmt.Fprintf(w, "Queued run #%d.\n", runID)
	}
	if !out.DaemonRunning && err == nil {
		fmt.Fprintln(w, daemonNotRunningNote)
	}
	return nil
}

// runTrigger is the trigger of a CLI run of a (spec §7.1): a rerun of one of
// its own runs is 'manual'; otherwise a button automation's run is 'button'
// and any other's 'manual'.
func runTrigger(database *db.DB, a *db.Automation, rerunOf int64) (string, error) {
	if rerunOf == 0 {
		if a.TriggerKind == string(automations.TriggerButton) {
			return db.TriggerButton, nil
		}
		return db.TriggerManual, nil
	}
	prev, err := database.GetAutomationRun(rerunOf)
	if err != nil {
		return "", fmt.Errorf("--rerun-of: %w", err)
	}
	if prev.AutomationID != a.ID {
		return "", fmt.Errorf("--rerun-of: run %d belongs to automation %d, not %d", rerunOf, prev.AutomationID, a.ID)
	}
	return db.TriggerManual, nil
}

// runAutomationsDryRun executes a dry run in this process (spec §10): the run
// row is trigger='dry_run', writes are journalled as dry_run, state and
// outputs are never committed, real llm tokens count. A dry run is exempt
// from the confirmation gate because it writes nothing (AUTO-12), but a dry
// run of an unconfirmed recipe is the owner's alone (D16, ask #271): under
// any AGENT-07 marker it is refused before a run row exists, so an agent
// cannot read data through a manifest the owner never confirmed.
func runAutomationsDryRun(cmd *cobra.Command, args []string) error {
	if (len(args) == 1) == (autoFlags.File != "") {
		return errors.New("pass an automation id or --file F (one of them)")
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := dryRunTarget(cmd.Context(), cfg, database, args)
	if err != nil {
		return err
	}
	if !automationConfirmed(a) {
		if err := refuseUnderAgent("dry-run a recipe that is not confirmed yet"); err != nil {
			return fmt.Errorf("%w; %s", err, dryRunUnconfirmedHint)
		}
	}
	runID, _, err := database.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerDryRun, Now: time.Now()})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	exec := automations.NewExecutor(database, automations.Backends{
		DB:        database,
		Generator: automationsDryRunGenerator(cfg),
		Registry:  buildAutomationRegistry(cfg, database),
		Clock:     automations.RealClock{},
	}, automations.ExecutorOptions{DailyBudgetTokens: cfg.Automations.DailyBudgetTokens})
	run, err := exec.ExecuteInline(ctx, runID)
	if err != nil {
		return err
	}
	out := dryRunJSON{RunID: run.ID, Status: run.Status, Error: run.Error, InputTokens: run.InputTokens, OutputTokens: run.OutputTokens}
	if autoFlags.JSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	return printDryRun(cmd, database, a, out)
}

func printDryRun(cmd *cobra.Command, database *db.DB, a *db.Automation, out dryRunJSON) error {
	steps, err := database.ListAutomationRunSteps(out.RunID)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	fmt.Fprintf(w, "Dry run #%d of %s (#%d): %s, %d+%d tokens\n", out.RunID, a.Slug, a.ID, out.Status,
		out.InputTokens, out.OutputTokens)
	if out.Error != "" {
		fmt.Fprintf(w, "  error: %s\n", out.Error)
	}
	printAutomationSteps(cmd, steps)
	return nil
}

// dryRunTarget is the automation a dry run executes: <id>, or the index row
// of --file, which must lie in the personal folder or a workbench's
// .watchtower/automations folder (that folder is rescanned first, so the run
// uses the file as it is now).
func dryRunTarget(ctx context.Context, cfg *config.Config, database *db.DB, args []string) (*db.Automation, error) {
	if len(args) == 1 {
		id, err := parseAutomationID("automation id", args[0])
		if err != nil {
			return nil, err
		}
		return database.GetAutomation(id)
	}
	scope, dir, path, ok, err := recipeFolderOf(cfg, database, autoFlags.File)
	if err != nil {
		return nil, err
	}
	if !ok || filepath.Ext(path) != ".md" {
		return nil, fmt.Errorf("%s is not a recipe in a recipe folder — save it first (`watchtower automations save --file %s`)",
			autoFlags.File, autoFlags.File)
	}
	return indexedRecipeAt(ctx, cfg, database, scope, dir, path)
}

func runAutomationsCancel(cmd *cobra.Command, args []string) error {
	runID, err := parseAutomationID("run id", args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	cancelled, err := database.CancelAutomationRun(runID, time.Now())
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if !cancelled {
		fmt.Fprintf(w, "Run #%d had already finished.\n", runID)
		return nil
	}
	// The executor notices a cancelled running run on its next status poll;
	// a wake makes that now.
	if _, err := wakeAutomations(cfg); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: run #%d is cancelled, but the daemon was not woken: %v\n", runID, err)
	}
	fmt.Fprintf(w, "Run #%d cancelled.\n", runID)
	return nil
}
