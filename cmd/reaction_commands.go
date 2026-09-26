package cmd

import (
	"context"
	"fmt"
	"log"
	"text/tabwriter"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reactioncmd"
	watchtowerslack "watchtower/internal/slack"

	"github.com/spf13/cobra"
)

// reactionCommandsAccountsFn resolves each enabled Slack account's owner token
// into a live client at run time, so a re-login mid-daemon is picked up on the
// next poll; one account's missing token is skipped, never blocking the others.
func reactionCommandsAccountsFn(database *db.DB, cfg *config.Config, logger *log.Logger) func(context.Context) ([]reactioncmd.Account, error) {
	return func(context.Context) ([]reactioncmd.Account, error) {
		accounts, err := database.ListEnabledSlackAccounts()
		if err != nil {
			return nil, err
		}
		var out []reactioncmd.Account
		for _, acct := range accounts {
			store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), acct.ID)
			token, err := store.Load()
			if err != nil || token == nil {
				if logger != nil {
					logger.Printf("reaction-commands: account %d: no usable token, skipping", acct.ID)
				}
				continue
			}
			client := watchtowerslack.NewClient(token.AccessToken)
			client.SetLogger(logger)
			out = append(out, reactioncmd.Account{
				AccountID: acct.ID,
				OwnerID:   acct.CurrentUserID,
				Lister:    client,
			})
		}
		return out, nil
	}
}

// newReactionCommandsPipeline is the ONE place the pipeline is assembled —
// shared by the daemon wiring and the CLI so they can never disagree.
func newReactionCommandsPipeline(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *reactioncmd.Pipeline {
	registry := buildToolRegistry(cfg, database)
	pipe := reactioncmd.New(database, cfg, gen, registry, reactionCommandsAccountsFn(database, cfg, logger), logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	return pipe
}

// wireReactionCommandsPipeline attaches the pipeline to the daemon
// unconditionally — the gate is at phase time (reaction_commands.enabled), not
// here (the wireIdeasPipeline precedent).
func wireReactionCommandsPipeline(d *daemon.Daemon, database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) {
	d.SetReactionCommandsPipeline(newReactionCommandsPipeline(database, cfg, gen, logger))
}

var reactionCommandsCmd = &cobra.Command{
	Use:   "reaction-commands",
	Short: "Drive Watchtower by reacting to Slack messages (owner reaction → agent-action)",
}

var reactionCommandsPollCmd = &cobra.Command{
	Use:   "poll",
	Short: "Poll reactions.list once now and dispatch any new commands (bypasses the daemon throttle)",
	RunE:  runReactionCommandsPoll,
}

var reactionCommandsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List recent reaction commands and their outcomes",
	RunE:  runReactionCommandsList,
}

func init() {
	rootCmd.AddCommand(reactionCommandsCmd)
	reactionCommandsCmd.AddCommand(reactionCommandsPollCmd, reactionCommandsListCmd)
}

func runReactionCommandsPoll(cmd *cobra.Command, _ []string) error {
	cfg, database, err := reactionCommandsConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[reaction-commands] ", log.LstdFlags)
	pipe := newReactionCommandsPipeline(database, cfg, cliGenerator(cfg), logger)

	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	dispatched, err := pipe.Run(ctx)
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "dispatched %d reaction command(s)\n", dispatched)
	return nil
}

func runReactionCommandsList(cmd *cobra.Command, _ []string) error {
	_, database, err := reactionCommandsConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()

	rows, err := database.ListRecentReactionCommands(50)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "no reaction commands yet")
		return nil
	}
	w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tEMOJI\tCHANNEL\tTS\tSTATUS\tACTION\tERROR")
	for _, r := range rows {
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%d\t%s\n",
			r.ID, r.Emoji, r.ChannelID, r.MessageTS, r.Status, r.ActionID, r.Error)
	}
	return w.Flush()
}

// reactionCommandsConfigAndDB loads config (with the usual workspace/provider
// flag overrides) and opens the workspace database — the ideasConfigAndDB
// per-feature-copy pattern.
func reactionCommandsConfigAndDB() (*config.Config, *db.DB, error) {
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
