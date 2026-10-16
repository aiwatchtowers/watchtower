package cmd

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/lockstats"

	"github.com/spf13/cobra"
)

var (
	dbLockstatsFlagSince time.Duration
	dbLockstatsFlagJSON  bool
)

var dbLockstatsCmd = &cobra.Command{
	Use:   "lockstats",
	Short: "Summarise the SQLite lock-metrics log (dblock.jsonl)",
	Long: "Summarise the slow write transactions, busy errors, lock holders, WAL samples\n" +
		"and pool waits recorded in dblock.jsonl (and its rotated .1) next to the database.",
	RunE: runDBLockstats,
}

func init() {
	dbLockstatsCmd.Flags().DurationVar(&dbLockstatsFlagSince, "since", 24*time.Hour, "only events from this long ago (e.g. 2h, 24h)")
	dbLockstatsCmd.Flags().BoolVar(&dbLockstatsFlagJSON, "json", false, "output JSON")
	dbCmd.AddCommand(dbLockstatsCmd)
}

func runDBLockstats(cmd *cobra.Command, _ []string) error {
	if dbLockstatsFlagSince <= 0 {
		return fmt.Errorf("--since must be positive, got %s", dbLockstatsFlagSince)
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	path := filepath.Join(filepath.Dir(cfg.DBPath()), lockmetrics.FileName)
	parsed, err := lockstats.ReadFiles([]string{path + ".1", path})
	if err != nil {
		return fmt.Errorf("db lockstats: %w", err)
	}
	out := cmd.OutOrStdout()
	if len(parsed.Files) == 0 {
		if _, err := fmt.Fprintf(out, "no lock events recorded yet (%s)\n", path); err != nil {
			return fmt.Errorf("db lockstats: %w", err)
		}
		return nil
	}

	report := lockstats.Build(parsed, time.Now().UTC(), dbLockstatsFlagSince)
	if dbLockstatsFlagJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		if err := enc.Encode(report); err != nil {
			return fmt.Errorf("db lockstats: encoding JSON: %w", err)
		}
		return nil
	}
	if err := lockstats.WriteText(out, report); err != nil {
		return fmt.Errorf("db lockstats: %w", err)
	}
	return nil
}
