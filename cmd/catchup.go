package cmd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"

	"github.com/spf13/cobra"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var (
	catchupFlagJSON   bool
	catchupFlagMaxAge int
	catchupFlagLimit  int

	// Deprecated flags from the old digest-since-checkpoint catchup command.
	// Kept hidden so a script using them gets a clear message instead of a bare
	// "unknown flag" error. They no longer affect behaviour.
	catchupFlagSince       string
	catchupFlagWatchedOnly bool
	catchupFlagChannel     string
)

var catchupCmd = &cobra.Command{
	Use:   "catchup",
	Short: "Summarize everything unread across digests, tracks, inbox, and briefings",
	Long: "Builds an on-demand AI rollup of exactly the currently-unread items across digests, " +
		"tracks, inbox, and briefings, clustered into cross-source thematic stories.\n\n" +
		"NOTE: this command changed semantics — it used to summarize Slack activity since a " +
		"timestamp (--since/--watched-only/--channel). Those flags are removed; it now reports " +
		"unread items. Use --max-age/--limit to bound the rollup.",
	RunE: runCatchup,
}

func init() {
	catchupCmd.Flags().BoolVar(&catchupFlagJSON, "json", false, "output result as JSON")
	catchupCmd.Flags().IntVar(&catchupFlagMaxAge, "max-age", 0, "override max age in days for unread items (0 = use config)")
	catchupCmd.Flags().IntVar(&catchupFlagLimit, "limit", 0, "override per-area cap; when >0 sets all area caps to this value (0 = use config)")

	// Hidden deprecated flags — accepted but inert, with a stderr notice (F3).
	catchupCmd.Flags().StringVar(&catchupFlagSince, "since", "", "deprecated: removed (catchup now reports unread items)")
	catchupCmd.Flags().BoolVar(&catchupFlagWatchedOnly, "watched-only", false, "deprecated: removed (catchup now reports unread items)")
	catchupCmd.Flags().StringVar(&catchupFlagChannel, "channel", "", "deprecated: removed (catchup now reports unread items)")
	_ = catchupCmd.Flags().MarkHidden("since")
	_ = catchupCmd.Flags().MarkHidden("watched-only")
	_ = catchupCmd.Flags().MarkHidden("channel")

	rootCmd.AddCommand(catchupCmd)
}

func runCatchup(cmd *cobra.Command, _ []string) error {
	for _, name := range []string{"since", "watched-only", "channel"} {
		if cmd.Flags().Changed(name) {
			fmt.Fprintf(cmd.ErrOrStderr(),
				"warning: --%s is removed; catchup now reports currently-unread items. See 'watchtower catchup --help'.\n", name)
		}
	}

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

	logger := log.New(os.Stderr, "", log.LstdFlags)
	gen := cliGenerator(cfg)
	sessionID, err := catchup.New(database, cfg, gen, logger).Run(cmd.Context())
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if sessionID == 0 {
		if catchupFlagJSON {
			enc := json.NewEncoder(out)
			enc.SetIndent("", "  ")
			return enc.Encode([]db.CatchupTheme{})
		}
		fmt.Fprintln(out, "All caught up — nothing unread.")
		return nil
	}

	themes, err := database.ListCatchupThemes(sessionID)
	if err != nil {
		return err
	}

	if catchupFlagJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(themes)
	}

	fmt.Fprintf(out, "Catch-Up — %d themes\n\n", len(themes))
	for _, t := range themes {
		flag := ""
		if t.NeedsYou {
			flag = " [needs you]"
		}
		fmt.Fprintf(out, "• (%s)%s %s\n  %s\n", t.Priority, flag, t.Title, t.Narrative)
	}
	return nil
}
