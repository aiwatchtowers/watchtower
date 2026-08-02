package cmd

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

var situationsCmd = &cobra.Command{
	Use:   "situations",
	Short: "Show open situations",
	Long:  "Displays situations — clusters of inbox signals composed into a single narrative, ranked by priority.",
	RunE:  runSituations,
}

var situationsShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show situation details",
	Args:  cobra.ExactArgs(1),
	RunE:  runSituationsShow,
}

func init() {
	rootCmd.AddCommand(situationsCmd)
	situationsCmd.AddCommand(situationsShowCmd)
}

func runSituations(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	out := cmd.OutOrStdout()

	items, err := database.ListOpenSituations()
	if err != nil {
		return fmt.Errorf("querying situations: %w", err)
	}

	if len(items) == 0 {
		fmt.Fprintln(out, "No open situations found.")
		return nil
	}

	fmt.Fprintf(out, "Situations (%d)\n\n", len(items))

	for _, item := range items {
		pLabel := strings.ToUpper(item.Priority)
		switch item.Priority {
		case "high":
			pLabel = "HIGH"
		case "medium":
			pLabel = "MED "
		case "low":
			pLabel = "LOW "
		}

		reason := item.AIReason
		line := fmt.Sprintf(" %s  %s  [#%d] %s", pLabel, item.Kind, item.ID, item.Title)
		if reason != "" {
			line += fmt.Sprintf(" — %s", reason)
		}

		fmt.Fprintln(out, line)
	}

	return nil
}

func runSituationsShow(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid situation ID %q: must be a positive integer", args[0])
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	situation, err := database.GetSituation(id)
	if err != nil {
		return fmt.Errorf("situation #%d not found: %w", id, err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Situation #%d: %s\n", situation.ID, situation.Title)
	fmt.Fprintf(out, "Kind: %s | Status: %s | Priority: %s\n", situation.Kind, situation.Status, situation.Priority)

	if situation.WhyMatters != "" {
		fmt.Fprintf(out, "\nWhy it matters:\n%s\n", situation.WhyMatters)
	}
	if situation.Summary != "" {
		fmt.Fprintf(out, "\nSummary:\n%s\n", situation.Summary)
	}
	if situation.Chronology != "" {
		fmt.Fprintf(out, "\nChronology:\n%s\n", situation.Chronology)
	}

	signals, err := database.ListSituationSignals(id)
	if err != nil {
		return fmt.Errorf("listing situation signals: %w", err)
	}

	if len(signals) > 0 {
		fmt.Fprintf(out, "\nSignals (%d):\n", len(signals))
		for _, s := range signals {
			snippet := s.Snippet
			if len(snippet) > 80 {
				snippet = snippet[:80] + "..."
			}
			line := fmt.Sprintf("  - %s: %s", s.SenderUserID, snippet)
			if s.Permalink != "" {
				line += fmt.Sprintf(" (%s)", s.Permalink)
			}
			fmt.Fprintln(out, line)
		}
	}

	fmt.Fprintf(out, "\nCreated: %s | Updated: %s\n", situation.CreatedAt, situation.UpdatedAt)

	return nil
}
