package cmd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var (
	catchupRunFlagJSON      bool
	catchupRegenFlagComment string
	catchupFeedbackRating   string
	catchupFeedbackComment  string
)

var catchupCmd = &cobra.Command{
	Use:   "catchup",
	Short: "Review everything unread one theme at a time",
	Long: "Catch-Up builds a persisted review session that clusters the currently-unread " +
		"items across digests, tracks, inbox, and briefings into cross-source themes, then " +
		"lets you review them one at a time. Per-theme feedback trains every pipeline.\n\n" +
		"Subcommands:\n" +
		"  run                build a new review session (gather → outline → expand)\n" +
		"  regen <theme-id>   regenerate a single theme with an operator correction\n" +
		"  feedback <theme-id> record 👍/👎 (+ optional comment that derives learned rules)\n" +
		"  ack <theme-id>     acknowledge a theme (cascade mark-read over its sources)",
}

var catchupRunCmd = &cobra.Command{
	Use:   "run",
	Short: "Build a new catch-up review session",
	RunE:  runCatchupRun,
}

var catchupRegenCmd = &cobra.Command{
	Use:   "regen <theme-id>",
	Short: "Regenerate a single theme with a correction comment",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupRegen,
}

var catchupFeedbackCmd = &cobra.Command{
	Use:   "feedback <theme-id>",
	Short: "Record feedback on a theme (--rating up|down [--comment])",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupFeedback,
}

var catchupAckCmd = &cobra.Command{
	Use:   "ack <theme-id>",
	Short: "Acknowledge a theme and mark its sources read",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupAck,
}

func init() {
	rootCmd.AddCommand(catchupCmd)
	catchupCmd.AddCommand(catchupRunCmd, catchupRegenCmd, catchupFeedbackCmd, catchupAckCmd)

	catchupRunCmd.Flags().BoolVar(&catchupRunFlagJSON, "json", false, "output the resulting themes as JSON")
	catchupRegenCmd.Flags().StringVar(&catchupRegenFlagComment, "comment", "", "operator correction to apply when regenerating")
	catchupFeedbackCmd.Flags().StringVar(&catchupFeedbackRating, "rating", "", "up or down")
	catchupFeedbackCmd.Flags().StringVar(&catchupFeedbackComment, "comment", "", "free-text reason; a comment derives targeted learned rules")
}

// catchupPipeline loads config + DB and constructs a pooled-generator pipeline so
// the per-theme expand fan-out is bounded. It returns the pipeline, the database,
// and a cleanup func that closes the DB and the generator pool.
func catchupPipeline() (*catchup.Pipeline, *db.DB, func(), error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, nil, err
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, nil, fmt.Errorf("opening database: %w", err)
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	p := catchup.New(database, cfg, gen, logger)
	cleanup := func() {
		closeGen()
		_ = database.Close()
	}
	return p, database, cleanup, nil
}

func runCatchupRun(cmd *cobra.Command, _ []string) error {
	p, database, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	sessionID, err := p.Run(cmd.Context())
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if sessionID == 0 {
		if catchupRunFlagJSON {
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

	if catchupRunFlagJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(themes)
	}

	failed := 0
	for _, t := range themes {
		if t.GenState == "failed" {
			failed++
		}
	}
	if failed > 0 {
		fmt.Fprintf(out, "Catch-Up — %d themes (%d failed to expand)\n\n", len(themes), failed)
	} else {
		fmt.Fprintf(out, "Catch-Up — %d themes\n\n", len(themes))
	}
	for _, t := range themes {
		flag := ""
		if t.NeedsYou {
			flag = " [needs you]"
		}
		fmt.Fprintf(out, "[%d] (%s)%s %s\n  %s\n", t.ID, t.Priority, flag, t.Title, t.Narrative)
	}
	return nil
}

func runCatchupRegen(cmd *cobra.Command, args []string) error {
	themeID, err := parseThemeID(args[0])
	if err != nil {
		return err
	}
	p, _, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	if err := p.RegenTheme(cmd.Context(), themeID, catchupRegenFlagComment); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Regenerated theme %d.\n", themeID)
	return nil
}

func runCatchupFeedback(cmd *cobra.Command, args []string) error {
	themeID, err := parseThemeID(args[0])
	if err != nil {
		return err
	}
	rating, err := parseRating(catchupFeedbackRating)
	if err != nil {
		return err
	}
	p, _, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	if err := p.SubmitThemeFeedback(cmd.Context(), themeID, rating, catchupFeedbackComment); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Recorded feedback on theme %d.\n", themeID)
	return nil
}

func runCatchupAck(cmd *cobra.Command, args []string) error {
	themeID, err := parseThemeID(args[0])
	if err != nil {
		return err
	}
	p, _, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	if err := p.Acknowledge(themeID); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Acknowledged theme %d.\n", themeID)
	return nil
}

func parseThemeID(s string) (int64, error) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid theme id %q: %w", s, err)
	}
	return id, nil
}

// parseRating maps the CLI's up/down to the feedback rating (+1 / -1).
func parseRating(s string) (int, error) {
	switch s {
	case "up":
		return 1, nil
	case "down":
		return -1, nil
	default:
		return 0, fmt.Errorf("invalid --rating %q: must be up or down", s)
	}
}
