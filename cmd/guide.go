package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/userguide"
)

// guideSection is the pinned JSON shape the Desktop decodes (Ask Watchtower).
type guideSection struct {
	Page      string `json:"page"`
	PageTitle string `json:"page_title"`
	Heading   string `json:"heading"`
	Anchor    string `json:"anchor"`
	Level     int    `json:"level"`
	Text      string `json:"text"`
}

func toGuideSections(in []userguide.Section) []guideSection {
	out := make([]guideSection, 0, len(in))
	for _, s := range in {
		out = append(out, guideSection{s.Page, s.PageTitle, s.Heading, s.Anchor, s.Level, s.Text})
	}
	return out
}

var (
	guideIndexJSON   bool
	guideSearchJSON  bool
	guideSearchLimit = 5
)

var guideCmd = &cobra.Command{
	Use:   "guide",
	Short: "Search the embedded user guide",
}

var guideIndexCmd = &cobra.Command{
	Use:   "index",
	Short: "List every guide section",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		secs, err := userguide.Load()
		if err != nil {
			return fmt.Errorf("loading guide: %w", err)
		}
		if guideIndexJSON {
			return writeGuideJSON(cmd, map[string]any{
				"version":  Version,
				"base_url": userguide.BaseURL(Version),
				"catalog":  userguide.Catalog(),
				"sections": toGuideSections(secs),
			})
		}
		for _, s := range secs {
			fmt.Fprintf(cmd.OutOrStdout(), "%s\t%s\n", s.Page, s.Heading)
		}
		return nil
	},
}

var guideSearchCmd = &cobra.Command{
	Use:   "search <query>",
	Short: "Search the guide sections",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		secs, err := userguide.Load()
		if err != nil {
			return fmt.Errorf("loading guide: %w", err)
		}
		found := toGuideSections(userguide.Search(secs, args[0], guideSearchLimit))
		if guideSearchJSON {
			return writeGuideJSON(cmd, map[string]any{"sections": found})
		}
		for _, s := range found {
			fmt.Fprintf(cmd.OutOrStdout(), "%s\t%s\n", s.Page, s.Heading)
		}
		return nil
	},
}

var guideCatalogCmd = &cobra.Command{
	Use:   "catalog",
	Short: "Print the guide catalogue",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		fmt.Fprint(cmd.OutOrStdout(), userguide.Catalog())
		return nil
	},
}

func writeGuideJSON(cmd *cobra.Command, v any) error {
	enc := json.NewEncoder(cmd.OutOrStdout())
	return enc.Encode(v)
}

func init() {
	guideIndexCmd.Flags().BoolVar(&guideIndexJSON, "json", false, "Output JSON")
	guideSearchCmd.Flags().BoolVar(&guideSearchJSON, "json", false, "Output JSON")
	guideSearchCmd.Flags().IntVar(&guideSearchLimit, "limit", 5, "Maximum sections to return")
	guideCmd.AddCommand(guideIndexCmd, guideSearchCmd, guideCatalogCmd)
	rootCmd.AddCommand(guideCmd)
}
