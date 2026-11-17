package cmd

import (
	"fmt"

	"watchtower/internal/db"

	"github.com/spf13/cobra"
)

// dbWipeLLMCmd deletes all AI-generated data (db.WipeLLMData), the Go twin of
// the Desktop's Settings → Wipe LLM Data. The app stops the daemon, runs it,
// and starts the daemon again (AppState.stopWipeRestart).
var dbWipeLLMCmd = &cobra.Command{
	Use:   "wipe-llm",
	Short: "Delete all AI-generated data, keeping raw Slack data, config and your own targets",
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		database, err := db.Open(cfg.DBPath())
		if err != nil {
			return fmt.Errorf("opening database: %w", err)
		}
		defer database.Close()
		if err := database.WipeLLMData(); err != nil {
			return fmt.Errorf("db wipe-llm: %w", err)
		}
		_, err = fmt.Fprintln(cmd.OutOrStdout(), "AI-generated data wiped.")
		return err
	},
}

func init() {
	dbCmd.AddCommand(dbWipeLLMCmd)
}
