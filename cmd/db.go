package cmd

import (
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

var dbCmd = &cobra.Command{
	Use:   "db",
	Short: "Database management commands",
}

var dbMigrateCmd = &cobra.Command{
	Use:   "migrate",
	Short: "Apply pending database migrations",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := workspaceConfigFromFlags()
		if err != nil {
			return err
		}
		// The Desktop runs db migrate at every launch (BACKUP-01).
		applyBackupExclusion(cfg)
		database, err := db.Open(cfg.DBPath())
		if err != nil {
			return fmt.Errorf("opening database: %w", err)
		}
		defer database.Close()

		// Seed any new prompt templates added since last run
		store := prompts.New(database, nil)
		if err := store.Seed(); err != nil {
			return fmt.Errorf("seeding prompt templates: %w", err)
		}

		// After seeding: a table missing from one feature must not hold back
		// the prompts every other feature reads.
		if err := database.CheckSchemaDrift(); err != nil {
			return fmt.Errorf("db migrate: %w", err)
		}

		fmt.Println("Database migrations applied successfully.")
		return nil
	},
}

func init() {
	dbCmd.AddCommand(dbMigrateCmd)
	dbCmd.AddCommand(dbCompactCmd)
	rootCmd.AddCommand(dbCmd)
}
