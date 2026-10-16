package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

var workbenchColumnsCmd = &cobra.Command{
	Use:   "columns <id>",
	Short: "Show or replace a workbench's board columns and hidden statuses",
	Long: "Without --set it prints the workbench's column definition: the columns inside each status and\n" +
		"the hidden statuses. --json prints {\"columns\":[…],\"hidden\":[…]} (columns is never null).\n" +
		"--set - reads that JSON from stdin and replaces the whole definition atomically; a refused\n" +
		"definition prints why and writes nothing. A status with no columns has one implicit column.",
	Args: cobra.ExactArgs(1),
	RunE: runWorkbenchColumns,
}

var workbenchColumnsFlagSet string

func init() {
	c := workbenchColumnsCmd
	c.Flags().StringVar(&workbenchColumnsFlagSet, "set", "", `replace the definition with the JSON read from stdin (use "-")`)
	c.Flags().BoolVar(&workbenchFlagJSON, "json", false, "output JSON")
	workbenchCmd.AddCommand(c)
}

func runWorkbenchColumns(cmd *cobra.Command, args []string) error {
	id, err := parseWorkbenchID(args[0])
	if err != nil {
		return err
	}
	setting := cmd.Flags().Changed("set")
	var in db.BoardColumns
	if setting {
		if workbenchColumnsFlagSet != "-" {
			return fmt.Errorf(`--set reads the definition from stdin: use --set -`)
		}
		dec := json.NewDecoder(cmd.InOrStdin())
		if err := dec.Decode(&in); err != nil {
			return fmt.Errorf("reading the column definition from stdin: %w", err)
		}
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	var res db.BoardColumns
	if setting {
		res, err = database.ReplaceBoardColumns(id, in)
	} else {
		res, err = database.GetBoardColumns(id)
	}
	if err != nil {
		// Execute prints the error (a refused definition's Msg) to stderr.
		return err
	}
	if res.Columns == nil {
		res.Columns = []db.BoardColumn{}
	}
	if res.Hidden == nil {
		res.Hidden = []string{}
	}
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printBoardColumns(cmd.OutOrStdout(), res)
	return nil
}

// printBoardColumns is one line per status with its columns, then the
// hidden statuses.
func printBoardColumns(w io.Writer, b db.BoardColumns) {
	for _, status := range db.BoardStatusOrder {
		var titles []string
		for _, c := range b.Columns {
			if c.Status == status {
				titles = append(titles, c.Title)
			}
		}
		if len(titles) == 0 {
			titles = []string{db.BoardStatusLabels[status] + " (default)"}
		}
		fmt.Fprintf(w, "%s: %s\n", db.BoardStatusLabels[status], strings.Join(titles, ", "))
	}
	hidden := "none"
	if len(b.Hidden) > 0 {
		labels := make([]string, len(b.Hidden))
		for i, s := range b.Hidden {
			labels[i] = db.BoardStatusLabels[s]
		}
		hidden = strings.Join(labels, ", ")
	}
	fmt.Fprintf(w, "Hidden: %s\n", hidden)
}
