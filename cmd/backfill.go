package cmd

import (
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/spf13/cobra"
)

var backfillCmd = &cobra.Command{Use: "backfill", Short: "History backfill of newly connected sources"}

var backfillStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Progress of the history backfill per source",
	Args:  cobra.NoArgs,
	RunE:  runBackfillStatus,
}

var flagBackfillJSON bool

func init() {
	backfillStatusCmd.Flags().BoolVar(&flagBackfillJSON, "json", false, "print JSON")
	backfillCmd.AddCommand(backfillStatusCmd)
	rootCmd.AddCommand(backfillCmd)
}

// backfillRowJSON is the pinned --json row shape, kept stable for scripts
// and agents (the Desktop reads the history_backfill table directly).
type backfillRowJSON struct {
	Source    string  `json:"source"`
	AccountID int64   `json:"account_id"`
	Status    string  `json:"status"`
	Waiting   string  `json:"waiting"`
	DaysTotal int     `json:"days_total"`
	DaysDone  int     `json:"days_done"`
	LastError string  `json:"last_error"`
	StartedAt string  `json:"started_at"`
	DoneAt    *string `json:"done_at"`
}

// backfillWaiting is what holds the row: the stored waiting (plan_limit), or
// "held" while a transient failure holds its chunk (#580; held_since set,
// the reason in last_error). The Desktop's BackfillQueries reads it the same
// way.
func backfillWaiting(waiting string, held bool) string {
	if waiting == "" && held {
		return "held"
	}
	return waiting
}

func runBackfillStatus(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	rows, err := database.ListHistoryBackfills()
	if err != nil {
		return err
	}
	out := make([]backfillRowJSON, 0, len(rows))
	for _, r := range rows {
		row := backfillRowJSON{
			Source:    r.SourceKind,
			AccountID: r.AccountID,
			Status:    r.Status,
			Waiting:   backfillWaiting(r.Waiting, r.HeldSince != nil),
			DaysTotal: int(math.Round((r.UpperTS - r.FloorTS) / 86400)),
			DaysDone:  int(math.Round((r.UpperTS - r.ReachedTS) / 86400)),
			LastError: r.LastError,
			StartedAt: r.StartedAt.UTC().Format(time.RFC3339),
		}
		if r.DoneAt != nil {
			s := r.DoneAt.UTC().Format(time.RFC3339)
			row.DoneAt = &s
		}
		out = append(out, row)
	}
	w := cmd.OutOrStdout()
	if flagBackfillJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(struct {
			Backfills []backfillRowJSON `json:"backfills"`
		}{out})
	}
	if len(out) == 0 {
		fmt.Fprintln(w, "No history backfill.")
		return nil
	}
	for _, r := range out {
		line := fmt.Sprintf("%s #%d  %s  %d/%d days", r.Source, r.AccountID, r.Status, r.DaysDone, r.DaysTotal)
		if r.Waiting != "" {
			line += "  (waiting: " + r.Waiting + ")"
		}
		if r.LastError != "" {
			line += "  — " + r.LastError
		}
		fmt.Fprintln(w, line)
	}
	return nil
}
