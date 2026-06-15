package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var (
	catchupFlagJSON   bool
	catchupFlagMaxAge int
	catchupFlagLimit  int
)

var catchupCmd = &cobra.Command{
	Use:   "catchup",
	Short: "Summarize everything unread across digests, tracks, inbox, and briefings",
	Long:  "Builds an on-demand AI rollup of exactly the currently-unread items across digests, tracks, inbox, and briefings, clustered into cross-source thematic stories.",
	RunE:  runCatchup,
}

func init() {
	catchupCmd.Flags().BoolVar(&catchupFlagJSON, "json", false, "output result as JSON")
	catchupCmd.Flags().IntVar(&catchupFlagMaxAge, "max-age", 0, "override max age in days for unread items (0 = use config)")
	catchupCmd.Flags().IntVar(&catchupFlagLimit, "limit", 0, "override per-area cap; when >0 sets all area caps to this value (0 = use config)")
	rootCmd.AddCommand(catchupCmd)
}

func runCatchup(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}

	if catchupFlagMaxAge > 0 {
		cfg.Catchup.MaxAgeDays = catchupFlagMaxAge
	}
	if catchupFlagLimit > 0 {
		cfg.Catchup.Caps = config.CatchupCaps{
			Digests:   catchupFlagLimit,
			Tracks:    catchupFlagLimit,
			Inbox:     catchupFlagLimit,
			Briefings: catchupFlagLimit,
		}
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	gen := cliGenerator(cfg)
	result, err := catchup.New(database, cfg, gen).Run(cmd.Context())
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if catchupFlagJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(result)
	}

	fmt.Fprintf(out, "Catch-Up — %d unread (%d shown)\n\n", result.Counts.TotalUnread, result.Counts.TotalIncluded)
	if result.TLDR != "" {
		fmt.Fprintf(out, "%s\n\n", result.TLDR)
	}
	for _, s := range result.Stories {
		flag := ""
		if s.NeedsYou {
			flag = " [needs you]"
		}
		fmt.Fprintf(out, "• (%s)%s %s\n  %s\n", s.Priority, flag, s.Title, s.Narrative)
	}
	return nil
}
