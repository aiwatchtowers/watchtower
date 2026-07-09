package cmd

import (
	"fmt"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/feed"

	"github.com/spf13/cobra"
)

var feedCmd = &cobra.Command{
	Use:   "feed",
	Short: "Dashboard feed index utilities",
}

var feedPublishCmd = &cobra.Command{
	Use:   "publish",
	Short: "Publish feed items from source tables (AI-free, idempotent)",
	Long: `Mirrors open situations, upcoming meetings, briefings, meeting recaps, and
day plans into the dashboard feed index (feed_items). The daemon does this at
the end of every cycle; run it manually to bootstrap the feed right after an
upgrade (before the first cycle completes) or for debugging.`,
	RunE: runFeedPublish,
}

func init() {
	rootCmd.AddCommand(feedCmd)
	feedCmd.AddCommand(feedPublishCmd)
}

func runFeedPublish(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[feed] ", log.LstdFlags)
	n, err := feed.New(database, cfg, logger).Publish(time.Now())
	// Report the count even on a partial failure — sources are best-effort
	// independent (DASH-06), so some items may have published successfully.
	fmt.Fprintf(cmd.OutOrStdout(), "Feed: %d items published\n", n)
	if err != nil {
		return fmt.Errorf("feed publish: %w", err)
	}
	return nil
}
