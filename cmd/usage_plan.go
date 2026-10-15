package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/planusage"
)

var usageCmd = &cobra.Command{Use: "usage", Short: "Usage of your AI plans"}

var usagePlanCmd = &cobra.Command{
	Use:   "plan",
	Short: "Claude plan limits (5-hour, weekly) and when you hit them",
	RunE:  runUsagePlan,
}

var (
	flagUsagePlanJSON bool
	flagUsagePlanNow  bool
)

func init() {
	usagePlanCmd.Flags().BoolVar(&flagUsagePlanJSON, "json", false, "print JSON")
	usagePlanCmd.Flags().BoolVar(&flagUsagePlanNow, "now", false, "poll once before printing")
	usageCmd.AddCommand(usagePlanCmd)
	rootCmd.AddCommand(usageCmd)
}

// usagePlanJSON is the pinned --json shape; the Desktop and a test depend on
// these keys.
type usagePlanJSON struct {
	State     string                   `json:"state"`
	Reason    string                   `json:"reason"`
	Plan      string                   `json:"plan"`
	FetchedAt *time.Time               `json:"fetched_at"`
	LastError string                   `json:"last_error"`
	Limits    []planusage.Limit        `json:"limits"`
	Breakdown []planusage.BreakdownRow `json:"breakdown"`
}

func runUsagePlan(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	var pollErr error
	if flagUsagePlanNow {
		_, pollErr = newPlanUsagePoller(database, log.New(io.Discard, "", 0)).PollOnce(cmd.Context())
	}
	st, err := database.GetPlanUsageStatus()
	if err != nil {
		return err
	}
	out := usagePlanJSON{Limits: []planusage.Limit{}, Breakdown: []planusage.BreakdownRow{}}
	if st != nil {
		out.State, out.Reason, out.Plan, out.FetchedAt, out.LastError = st.State, st.Reason, st.Plan, st.FetchedAt, st.LastError
		if err := json.Unmarshal([]byte(st.LimitsJSON), &out.Limits); err != nil {
			return fmt.Errorf("decoding limits: %w", err)
		}
		if err := json.Unmarshal([]byte(st.BreakdownJSON), &out.Breakdown); err != nil {
			return fmt.Errorf("decoding breakdown: %w", err)
		}
	}
	w := cmd.OutOrStdout()
	if flagUsagePlanJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(out); err != nil {
			return err
		}
		return pollErr
	}
	if st == nil {
		fmt.Fprintln(w, "No Claude plan usage yet — the daemon polls every 5 minutes (or run `watchtower usage plan --now`).")
		return pollErr
	}
	fmt.Fprintf(w, "Claude plan (%s) — %s", out.Plan, out.State)
	if out.Reason != "" {
		fmt.Fprintf(w, " (%s)", out.Reason)
	}
	fmt.Fprintln(w)
	for _, l := range out.Limits {
		fmt.Fprintf(w, "  %-18s %5.1f%%  %s  %s\n", l.Label, l.Percent, resetText(l.ResetsAt), projectionText(l.Projection))
	}
	return pollErr
}

func resetText(t *time.Time) string {
	if t == nil {
		return "not started"
	}
	return "resets " + t.Local().Format("Mon 15:04")
}

func projectionText(p planusage.Projection) string {
	switch p.State {
	case "will_hit":
		if p.HitAt == nil {
			return "will hit the limit"
		}
		return "hits " + p.HitAt.Local().Format("Mon 15:04")
	case "hit":
		return "limit reached"
	case "collecting":
		return "collecting data"
	case "idle":
		return ""
	default:
		return "won't hit before reset"
	}
}
