package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"watchtower/internal/learn"
)

// guideCmd groups commands over the embedded user guide. They read only the
// binary's own guide: no config, no database.
var guideCmd = &cobra.Command{
	Use:               "guide",
	Short:             "The embedded user guide",
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
}

var guideLearnFlagJSON bool

var guideLearnCmd = &cobra.Command{
	Use:   "learn [--json]",
	Short: "List Home's Learn cards from the user guide",
	Long: `List the Learn cards written in the user guide (design
2026-10-19-home-zones-design.md §9), validated.

--json prints one line: {"cards":[{"id","title","text","area","level","kind",
"since","action","changed","done_when","requires","replaces":[],"page",
"anchor","hotkey_label"}],"retired":[…]}. Empty optional values are "" and an
empty replaces is []. An invalid card is an error (exit 1).`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cat, err := learn.Load()
		if err != nil {
			return fmt.Errorf("guide learn cards: %w", err)
		}
		return writeLearnCatalog(cmd.OutOrStdout(), cat, guideLearnFlagJSON)
	},
}

func writeLearnCatalog(out io.Writer, cat learn.Catalog, asJSON bool) error {
	if asJSON {
		return json.NewEncoder(out).Encode(cat)
	}
	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tAREA\tLEVEL\tKIND\tSINCE\tTITLE")
	for _, c := range cat.Cards {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", c.ID, c.Area, c.Level, c.Kind, c.Since, c.Title)
	}
	if err := w.Flush(); err != nil {
		return err
	}
	_, err := fmt.Fprintf(out, "%d cards, %d retired ids\n", len(cat.Cards), len(cat.Retired))
	return err
}

func init() {
	guideLearnCmd.Flags().BoolVar(&guideLearnFlagJSON, "json", false, "print the catalog as one JSON line")
	guideCmd.AddCommand(guideLearnCmd)
	rootCmd.AddCommand(guideCmd)
}
