package cmd

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/inbox"

	"github.com/spf13/cobra"
)

var profileCmd = &cobra.Command{
	Use:   "profile",
	Short: "Show current user profile",
	Long: `Display the current user profile used for personalization.

The profile includes your role, team, reports, peers, manager,
starred channels/people, and other settings that influence
how Watchtower prioritizes tracks and generates insights.`,
	RunE: runProfile,
}

var profileStyleSampleCmd = &cobra.Command{
	Use:   "style-sample",
	Short: "Distill a communication style profile from your own Slack messages",
	Args:  cobra.NoArgs,
	RunE:  runProfileStyleSample,
}

func init() {
	rootCmd.AddCommand(profileCmd)
	profileCmd.AddCommand(profileStyleSampleCmd)
}

func runProfile(cmd *cobra.Command, _ []string) error {
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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// Get current user ID from account #1.
	userID, err := database.GetCurrentUserID()
	if err != nil {
		return fmt.Errorf("getting current user id: %w", err)
	}
	if userID == "" {
		return fmt.Errorf("no workspace found — run 'watchtower sync' first")
	}

	out := cmd.OutOrStdout()

	profile, err := database.GetUserProfile(userID)
	if err != nil {
		return fmt.Errorf("getting profile: %w", err)
	}
	if profile == nil {
		fmt.Fprintln(out, "No profile configured yet.")
		fmt.Fprintln(out, "Set up your profile in the Desktop app (Settings > Profile).")
		return nil
	}

	fmt.Fprintf(out, "Profile for %s\n\n", profile.SlackUserID)

	if profile.Role != "" {
		fmt.Fprintf(out, "  Role:             %s\n", profile.Role)
	}
	if profile.Team != "" {
		fmt.Fprintf(out, "  Team:             %s\n", profile.Team)
	}
	if profile.Manager != "" {
		fmt.Fprintf(out, "  Manager:          %s\n", profile.Manager)
	}
	printJSONList(out, "  Reports:          ", profile.Reports)
	printJSONList(out, "  Peers:            ", profile.Peers)
	printJSONList(out, "  Responsibilities: ", profile.Responsibilities)
	printJSONList(out, "  Starred channels: ", profile.StarredChannels)
	printJSONList(out, "  Starred people:   ", profile.StarredPeople)
	printJSONList(out, "  Pain points:      ", profile.PainPoints)
	printJSONList(out, "  Track focus:      ", profile.TrackFocus)

	if profile.OnboardingDone {
		fmt.Fprintln(out, "\n  Onboarding: done")
	} else {
		fmt.Fprintln(out, "\n  Onboarding: not completed")
	}

	if profile.CustomPromptContext != "" {
		fmt.Fprintf(out, "\n  Prompt context:\n    %s\n", profile.CustomPromptContext)
	}

	return nil
}

func runProfileStyleSample(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[profile] ", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	defer closeGen()

	pipe := inbox.New(database, cfg, gen, logger)
	if err := pipe.GenerateStyleProfile(cmd.Context()); err != nil {
		return err
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Style profile regenerated.")
	return nil
}

// printJSONList prints a JSON array as a comma-separated line. Skips if empty.
func printJSONList(w interface{ Write([]byte) (int, error) }, prefix, jsonArr string) {
	if jsonArr == "" || jsonArr == "[]" {
		return
	}
	var items []string
	if err := json.Unmarshal([]byte(jsonArr), &items); err != nil {
		fmt.Fprintf(w, "%s(invalid JSON)\n", prefix)
		return
	}
	if len(items) == 0 {
		return
	}
	fmt.Fprintf(w, "%s%s\n", prefix, strings.Join(items, ", "))
}
