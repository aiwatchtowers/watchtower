package cmd

import (
	"context"
	"fmt"
	"log"
	"text/tabwriter"

	"watchtower/internal/config"
	"watchtower/internal/db"
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

	ideasListCmd.Flags().String("kind", "", "filter by kind (idea, decision, note)")
	ideasListCmd.Flags().String("status", "", "filter by status (proposed, active, rejected, merged, superseded, converted)")
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
