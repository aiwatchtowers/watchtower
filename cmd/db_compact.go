package cmd

import (
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

--check reports whether a compaction is due and writes nothing. --if-due
compacts only when due. Without --force it refuses while the daemon runs or
when the volume has less than twice the file's size free.

Exit codes: 0 compacted or not due, 1 error, 2 not enough disk space,
3 the daemon is running, 4 interrupted, 5 migrations pending
(run 'watchtower db migrate'). With --json the result is the last stdout line.`,
	Args: cobra.NoArgs,
	RunE: runDBCompact,
}

// daemonRunningForCompact reports whether the daemon runs, through the pid
// file check `sync stop` uses (a stale file naming a gone or reused pid reads
// as not running). A pid whose identity cannot be confirmed, or a pid file
// that cannot be read, reads as running: fail safe, --force overrides. A seam
// for tests.
var daemonRunningForCompact = func(cfg *config.Config) bool {
	pid, err := daemon.FindConfirmedProcess(pidFilePath(cfg))
	return pid != 0 || err != nil
}

func runDBCompact(cmd *cobra.Command, _ []string) error {
	if dbCompactFlagCheck && (dbCompactFlagIfDue || dbCompactFlagForce) {
		return errors.New("--check takes neither --if-due nor --force")
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}
	dbPath := cfg.DBPath()
	out := cmd.OutOrStdout()

	if dbCompactFlagCheck {
		c, err := db.CheckCompaction(dbPath, Version)
		if err != nil {
			return err
		}
		return printCompactCheck(out, filepath.Base(dbPath), c)
	}

	res, err := compactDatabase(cmd, cfg, dbPath)
	return reportCompact(out, filepath.Base(dbPath), res, err)
}

// compactDatabase runs the --if-due check, the daemon rule and Compact under
// the shutdown context, so SIGTERM interrupts the VACUUM.
func compactDatabase(cmd *cobra.Command, cfg *config.Config, dbPath string) (db.CompactResult, error) {
	reason := "manual"
	if dbCompactFlagIfDue {
		c, err := db.CheckCompaction(dbPath, Version)
		if err != nil {
			return db.CompactResult{}, err
		}
		// schema_pending and gave_up are not due either: the check said no.
		if !c.Due {
			return db.CompactResult{Skipped: "not_due"}, nil
		}
		reason = c.Reason
	}
	if !dbCompactFlagForce && daemonRunningForCompact(cfg) {
		return db.CompactResult{Skipped: "daemon_running", Reason: reason}, nil
	}
	ctx, cancel := notifyShutdownContext(cmd.Context(), stderrLogf)
	defer cancel()
	return db.Compact(ctx, dbPath, db.CompactOptions{Force: dbCompactFlagForce, Reason: reason, Version: Version})
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
		return &exitCodeError{code: code, err: errors.New(compactSkipMessage(name, res.Skipped))}
	case dbCompactFlagJSON:
		return nil
	case res.Compacted:
		d := time.Duration(res.DurationMS) * time.Millisecond
		if d >= time.Second {
			d = d.Round(time.Second)
		}
		_, err := fmt.Fprintf(out, "Compacted %s: %s → %s in %s\n", name, humanBytes(res.BytesBefore), humanBytes(res.BytesAfter), d)
		return err
	}
	_, err = fmt.Fprintf(out, "%s does not need compacting.\n", name)
	return err
}

func compactSkipMessage(name, skipped string) string {
	switch skipped {
	case "disk":
		return fmt.Sprintf("not compacting %s: the volume needs twice the file's size free (pass --force to try anyway)", name)
	case "daemon_running":
		return fmt.Sprintf("not compacting %s: the daemon is running; stop it with 'watchtower sync stop' (or pass --force)", name)
	case "interrupted":
		return fmt.Sprintf("compacting %s was interrupted; the database is unchanged", name)
	case "schema_pending":
		return fmt.Sprintf("not compacting %s: migrations are pending; run 'watchtower db migrate' first", name)
	}
	return fmt.Sprintf("not compacting %s: %s", name, skipped)
}

// humanBytes formats n in decimal units, as the Desktop's ByteCountFormatter
// .file style does ("3.4 GB").
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
