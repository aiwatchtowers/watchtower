package cmd

import (
	"context"
	"fmt"
	"log"
	"slices"
	"strings"
	"text/tabwriter"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

var ideasCmd = &cobra.Command{
	Use:   "ideas",
	Short: "Inspect and mine the ideas & decisions registry",
}

var ideasMineCmd = &cobra.Command{
	Use:   "mine",
	Short: "Run one ideas registry pass (Gmail/Jira pre-digests, then consolidation)",
	RunE:  runIdeasMine,
}

var ideasListCmd = &cobra.Command{
	Use:   "list",
	Short: "List ideas in the registry",
	RunE:  runIdeasList,
}

func init() {
	rootCmd.AddCommand(ideasCmd)
	ideasCmd.AddCommand(ideasMineCmd, ideasListCmd)

	ideasListCmd.Flags().String("kind", "", "filter by kind ("+strings.Join(ideaKinds, ", ")+")")
	ideasListCmd.Flags().String("status", "", "filter by status ("+strings.Join(ideaStatuses, ", ")+")")
}

// ideaKinds and ideaStatuses mirror the ideas table's CHECK constraints
// (migration 00050). An unknown filter value would otherwise be accepted
// silently and return an empty list, which reads as "you have no ideas"
// rather than "you typoed the flag".
var (
	ideaKinds    = []string{"idea", "decision", "note"}
	ideaStatuses = []string{"proposed", "active", "rejected", "not_now", "converted", "dropped", "merged", "superseded", "reversed"}
)

// validateEnumFlag returns an error naming the valid values when value is set
// but not among them. An empty value means "unfiltered" and always passes.
func validateEnumFlag(flag, value string, allowed []string) error {
	if value == "" || slices.Contains(allowed, value) {
		return nil
	}
	return fmt.Errorf("invalid --%s %q (valid: %s)", flag, value, strings.Join(allowed, ", "))
}

// wireIdeasPipeline attaches the ideas registry phase to the daemon when
// enabled (the wireMemoryPipeline precedent — it also keeps runSync under the
// cyclomatic-complexity gate).
func wireIdeasPipeline(d *daemon.Daemon, database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) {
	if !cfg.Ideas.Enabled {
		return
	}
	ideasPipe := ideas.New(database, cfg, gen, logger)
	ideasPipe.SetPromptStore(prompts.New(database, nil))
	d.SetIdeasPipeline(ideasPipe)
}

// ideasConfigAndDB loads the config (with the usual workspace/provider flag
// overrides) and opens the workspace database — the memoryConfigAndDB
// pattern.
func ideasConfigAndDB() (*config.Config, *db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, fmt.Errorf("invalid config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

func runIdeasMine(cmd *cobra.Command, _ []string) error {
	cfg, database, err := ideasConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	if !cfg.Ideas.Enabled {
		fmt.Fprintln(out, "Ideas registry is disabled (ideas.enabled = false in config); nothing to do.")
		return nil
	}

	logger := log.New(cmd.ErrOrStderr(), "[ideas] ", log.LstdFlags)
	pipe := ideas.New(database, cfg, cliGenerator(cfg), logger)
	pipe.SetPromptStore(prompts.New(database, nil))

	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	proposed, err := pipe.Run(ctx)
	if err != nil {
		return fmt.Errorf("mining ideas: %w", err)
	}

	inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
	fmt.Fprintf(out, "proposed=%d (input tokens: %d, output tokens: %d, API calls: %d)\n", proposed, inTok, outTok, totalAPI)
	return nil
}

func runIdeasList(cmd *cobra.Command, _ []string) error {
	kind, _ := cmd.Flags().GetString("kind")
	status, _ := cmd.Flags().GetString("status")
	if err := validateEnumFlag("kind", kind, ideaKinds); err != nil {
		return err
	}
	if err := validateEnumFlag("status", status, ideaStatuses); err != nil {
		return err
	}

	_, database, err := ideasConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	rows, err := database.ListIdeas(db.IdeaFilter{Kind: kind, Status: status})
	if err != nil {
		return fmt.Errorf("listing ideas: %w", err)
	}
	if len(rows) == 0 {
		fmt.Fprintln(out, "No ideas found.")
		return nil
	}

	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tKIND\tSTATUS\tTITLE\tLAST MENTION")
	for _, idea := range rows {
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", idea.ID, idea.Kind, idea.Status, idea.Title, idea.LastMentionAt)
	}
	return w.Flush()
}
