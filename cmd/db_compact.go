package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
)

var (
	dbCompactFlagCheck bool
	dbCompactFlagIfDue bool
	dbCompactFlagForce bool
	dbCompactFlagJSON  bool
)

var dbCompactCmd = &cobra.Command{
	Use:   "compact [--check | --if-due] [--force] [--json]",
	Short: "Rewrite the database file to return its free pages to the disk (VACUUM)",
	Long: `Compacts watchtower.db with VACUUM. Never migrates and never creates the file.

When an update left the search index of messages to rebuild, the run
rebuilds it first, then compacts — even when earlier compactions failed and
gave up, since the rebuild has its own rule. An interrupted rebuild resumes
on the next run.

--check reports whether a compaction or the search index rebuild is due and
writes nothing. --if-due runs only when due. Without --force it refuses while
the daemon runs, when the volume has less than twice the file's size free
for the compaction, or less than one and a half times the old search index's
size for the rebuild.

Exit codes: 0 compacted or not due, 1 error, 2 not enough disk space,
3 the daemon is running, 4 interrupted, 5 migrations pending
(run 'watchtower db migrate'). With --json a {"phase":"fts_rebuild"} or
{"phase":"compact"} line comes before each step, and the result is the last
stdout line.`,
	Args: cobra.NoArgs,
	// Not the root's ensureSchemaFormat: compaction never migrates or
	// upgrades, and --check writes nothing — the config included.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	RunE:              runDBCompact,
}

// daemonRunningForCompact reports whether the daemon runs, through the pid
// file check `sync stop` uses (a stale file naming a gone or reused pid reads
// as not running). A live pid whose identity cannot be confirmed reads as
// running: fail safe, --force overrides. A pid file that cannot be read or
// parsed names no process, so it reads as not running. A seam for tests.
var daemonRunningForCompact = func(cfg *config.Config) bool {
	pid, err := daemon.FindConfirmedProcess(pidFilePath(cfg))
	if err != nil {
		return errors.Is(err, daemon.ErrIdentityUnconfirmed)
	}
	return pid != 0
}

func runDBCompact(cmd *cobra.Command, _ []string) error {
	out := cmd.OutOrStdout()
	if dbCompactFlagCheck && (dbCompactFlagIfDue || dbCompactFlagForce) {
		return compactSetupFailed(out, errors.New("--check takes neither --if-due nor --force"))
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return compactSetupFailed(out, fmt.Errorf("loading config: %w", err))
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return compactSetupFailed(out, err)
	}
	dbPath := cfg.DBPath()

	if dbCompactFlagCheck {
		c, err := db.CheckCompaction(dbPath, Version)
		if err != nil {
			return compactSetupFailed(out, err)
		}
		return printCompactCheck(out, filepath.Base(dbPath), c)
	}

	res, err := compactDatabase(cmd, cfg, dbPath)
	return reportCompact(out, filepath.Base(dbPath), res, err)
}

// compactSetupFailed reports an error that comes before any compaction (flag
// misuse, config, workspace, the --check read): with --json it prints one
// result line with error filled, so a caller decoding stdout always gets one.
// Exit 1 either way.
func compactSetupFailed(out io.Writer, err error) error {
	if dbCompactFlagJSON {
		if encErr := json.NewEncoder(out).Encode(db.CompactResult{Error: err.Error()}); encErr != nil {
			return errors.Join(err, fmt.Errorf("printing the result: %w", encErr))
		}
	}
	return err
}

// compactDatabase runs the check, the daemon rule, the messages search fill
// when it is pending and then Compact, all under the shutdown context, so
// SIGTERM anywhere in it — the checks and the fill included — ends as
// interrupted (exit 4). A manual run reads the check only for the pending
// fill. A fill that is skipped or fails ends the run with Reason
// "fts_rebuild": the VACUUM never runs before the fill is complete, and a
// fill error is not counted in compact_failures (Compact's cap is its own).
// After the fill, --if-due checks again: the dropped legacy index may or may
// not make a compaction due.
func compactDatabase(cmd *cobra.Command, cfg *config.Config, dbPath string) (db.CompactResult, error) {
	ctx, cancel := notifyShutdownContext(cmd.Context(), stderrLogf)
	defer cancel()
	out, name := cmd.OutOrStdout(), filepath.Base(dbPath)
	c, res, done, err := compactCheckStep(ctx, dbPath)
	if done {
		return res, err
	}
	reason := "manual"
	if dbCompactFlagIfDue {
		reason = c.Reason
	}
	if !dbCompactFlagForce && daemonRunningForCompact(cfg) {
		return db.CompactResult{Skipped: "daemon_running", Reason: reason}, nil
	}
	ftsRebuilt := false
	if c.FTSRebuildPending {
		if err := printCompactPhase(out, name, "fts_rebuild"); err != nil {
			return db.CompactResult{Reason: "fts_rebuild"}, err
		}
		fill, err := db.RebuildMessagesSearchAt(ctx, dbPath, db.FTSRebuildRunOptions{Force: dbCompactFlagForce})
		if err != nil || fill.Skipped != "" {
			fill.Reason = "fts_rebuild"
			return fill, err
		}
		// Complete, whether this run or another process finished it.
		ftsRebuilt = true
		if dbCompactFlagIfDue {
			c, res, done, err = compactCheckStep(ctx, dbPath)
			if done {
				res.FTSRebuilt = true
				return res, err
			}
			reason = c.Reason
		}
	}
	if err := printCompactPhase(out, name, "compact"); err != nil {
		return db.CompactResult{Reason: reason, FTSRebuilt: ftsRebuilt}, err
	}
	res, err = db.Compact(ctx, dbPath, db.CompactOptions{Force: dbCompactFlagForce, Reason: reason, Version: Version})
	res.FTSRebuilt = ftsRebuilt
	return res, err
}

// compactCheckStep runs CheckCompaction for compactDatabase. done reports
// that the run ends here with (res, err): interrupted, a failed check, or —
// with --if-due — not due (schema_pending and gave_up are not due either:
// the check said no).
func compactCheckStep(ctx context.Context, dbPath string) (c db.CompactCheck, res db.CompactResult, done bool, err error) {
	c, err = db.CheckCompaction(dbPath, Version)
	if ctx.Err() != nil {
		return c, db.CompactResult{Skipped: "interrupted"}, true, nil //nolint:nilerr // a shutdown is a skip (exit 4), not an error
	}
	if err != nil {
		return c, db.CompactResult{}, true, err
	}
	if dbCompactFlagIfDue && !c.Due {
		return c, db.CompactResult{Skipped: "not_due"}, true, nil
	}
	return c, db.CompactResult{}, false, nil
}

// compactPhaseLine is the {"phase":…} line --json prints before each step of
// a run; the Desktop's launch splash reads it. Phases: "fts_rebuild",
// "compact".
type compactPhaseLine struct {
	Phase string `json:"phase"`
}

// printCompactPhase announces the step a run starts: with --json a phase line
// on stdout (the result line still comes last), otherwise a human line for
// the search index fill and nothing for the compaction.
func printCompactPhase(out io.Writer, name, phase string) error {
	var err error
	switch {
	case dbCompactFlagJSON:
		err = json.NewEncoder(out).Encode(compactPhaseLine{Phase: phase})
	case phase == "fts_rebuild":
		_, err = fmt.Fprintf(out, "Updating the search index of %s…\n", name)
	}
	if err != nil {
		return fmt.Errorf("printing the phase: %w", err)
	}
	return nil
}

// compactExitCode maps a result/err to 0..5 per the spec.
func compactExitCode(res db.CompactResult, err error) int {
	if err != nil {
		return 1
	}
	switch res.Skipped {
	case "disk":
		return 2
	case "daemon_running":
		return 3
	case "interrupted":
		return 4
	case "schema_pending":
		return 5
	}
	return 0
}

func printCompactCheck(out io.Writer, name string, c db.CompactCheck) error {
	if dbCompactFlagJSON {
		return json.NewEncoder(out).Encode(c)
	}
	switch {
	case c.Reason == "fts_rebuild" && !c.DiskOK:
		_, err := fmt.Fprintf(out, "%s needs its search index rebuilt (fts_rebuild) but needs %s free, %s available.\n",
			name, humanBytes(c.NeedsDiskBytes), humanBytes(c.FreeDiskBytes))
		return err
	case c.Reason == "fts_rebuild":
		_, err := fmt.Fprintf(out, "%s needs its search index rebuilt (fts_rebuild).\n", name)
		return err
	case c.Due && !c.DiskOK:
		_, err := fmt.Fprintf(out, "%s is due for compacting (%s) but needs %s free, %s available.\n",
			name, c.Reason, humanBytes(c.NeedsDiskBytes), humanBytes(c.FreeDiskBytes))
		return err
	case c.Due:
		_, err := fmt.Fprintf(out, "%s (%s) is due for compacting (%s).\n", name, humanBytes(c.DBBytes), c.Reason)
		return err
	case c.Reason != "":
		_, err := fmt.Fprintf(out, "%s is not due for compacting (%s).\n", name, c.Reason)
		return err
	}
	_, err := fmt.Fprintf(out, "%s does not need compacting.\n", name)
	return err
}

// reportCompact prints the result — the JSON line on every outcome with
// --json, errors included — and turns a non-zero exit into an error Execute
// prints to stderr.
func reportCompact(out io.Writer, name string, res db.CompactResult, err error) error {
	if err != nil && res.Error == "" {
		res.Error = err.Error()
	}
	code := compactExitCode(res, err)
	if dbCompactFlagJSON {
		if encErr := json.NewEncoder(out).Encode(res); encErr != nil {
			return errors.Join(err, fmt.Errorf("printing the result: %w", encErr))
		}
	}
	switch {
	case err != nil:
		return err
	case code != 0:
		return &exitCodeError{code: code, err: errors.New(compactSkipMessage(name, res))}
	case dbCompactFlagJSON:
		return nil
	case res.Compacted:
		d := time.Duration(res.DurationMS) * time.Millisecond
		if d >= time.Second {
			d = d.Round(time.Second)
		}
		_, err := fmt.Fprintf(out, "Compacted %s: %s → %s in %s\n", name, humanBytes(res.BytesBefore), humanBytes(res.BytesAfter), d)
		return err
	case res.FTSRebuilt:
		_, err := fmt.Fprintf(out, "Updated the search index of %s; it does not need compacting.\n", name)
		return err
	}
	_, err = fmt.Fprintf(out, "%s does not need compacting.\n", name)
	return err
}

// compactSkipMessage explains a skip; a skip of the search index fill
// carries Reason "fts_rebuild" (compactDatabase).
func compactSkipMessage(name string, res db.CompactResult) string {
	if res.Reason == "fts_rebuild" {
		switch res.Skipped {
		case "disk":
			return fmt.Sprintf("not updating the search index of %s: the volume needs one and a half times the old index's size free (pass --force to try anyway)", name)
		case "interrupted":
			return fmt.Sprintf("updating the search index of %s was interrupted; it continues where it stopped on the next run", name)
		}
	}
	skipped := res.Skipped
	switch skipped {
	case "disk":
		return fmt.Sprintf("not compacting %s: the volume needs twice the file's size free (pass --force to try anyway)", name)
	case "daemon_running":
		return fmt.Sprintf("not compacting %s: the daemon is running; stop it with 'watchtower sync stop' (or pass --force)", name)
	case "interrupted":
		return fmt.Sprintf("compacting %s was interrupted; it will be retried on the next launch", name)
	case "schema_pending":
		return fmt.Sprintf("not compacting %s: migrations are pending; run 'watchtower db migrate' first", name)
	}
	return fmt.Sprintf("not compacting %s: %s", name, skipped)
}

// humanBytes formats n in decimal units, as the Desktop's ByteCountFormatter
// .file style does ("2.0 GB").
func humanBytes(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d bytes", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
}

func init() {
	dbCompactCmd.Flags().BoolVar(&dbCompactFlagCheck, "check", false, "report whether a compaction is due; writes nothing")
	dbCompactCmd.Flags().BoolVar(&dbCompactFlagIfDue, "if-due", false, "compact only when a compaction is due")
	dbCompactCmd.Flags().BoolVar(&dbCompactFlagForce, "force", false, "compact even while the daemon runs or disk space looks short")
	dbCompactCmd.Flags().BoolVar(&dbCompactFlagJSON, "json", false, "print the result as one JSON line")
}
