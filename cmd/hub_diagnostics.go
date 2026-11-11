package cmd

import (
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/hub/measure"
	"watchtower/internal/hub/state"
)

// hubDiagnosticsMaxDays is the widest `hub diagnostics --days` window: the
// samples are kept 7 days (measure.Window).
const hubDiagnosticsMaxDays = int(measure.Window / (24 * time.Hour))

// hubDiagnosticsJSON is `hub diagnostics --json` (pinned keys).
type hubDiagnosticsJSON struct {
	WindowDays int                     `json:"window_days"`
	Rows       []hubDiagnosticsRowJSON `json:"rows"`
	// PushOverflowExpired counts the alert pushes dropped in the window
	// because too many were waiting for one phone.
	PushOverflowExpired int `json:"push_overflow_expired"`
}

// hubDiagnosticsRowJSON is one step on one transport (pinned keys).
type hubDiagnosticsRowJSON struct {
	Step      string `json:"step"`
	Transport string `json:"transport"`
	P50Ms     int64  `json:"p50_ms"`
	P90Ms     int64  `json:"p90_ms"`
	Samples   int    `json:"samples"`
}

func init() {
	diag := &cobra.Command{
		Use: "diagnostics", Short: "Show the hub's content-free timings (p50/p90 per step and transport)",
		Args: cobra.NoArgs, RunE: runHubDiagnostics,
	}
	diag.Flags().Bool("json", false, "print JSON")
	diag.Flags().Int("days", hubDiagnosticsMaxDays, fmt.Sprintf("the window in days (1..%d)", hubDiagnosticsMaxDays))
	hubCmd.AddCommand(diag)
}

// runHubDiagnostics prints the latency samples' percentiles and the
// overflowed pushes of the window, read from the sidecar without a hub; no
// sidecar reads as no timings.
func runHubDiagnostics(cmd *cobra.Command, _ []string) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	days, _ := cmd.Flags().GetInt("days")
	if days < 1 || days > hubDiagnosticsMaxDays {
		return fmt.Errorf("--days must be 1..%d", hubDiagnosticsMaxDays)
	}
	dir, err := hubDir()
	if err != nil {
		return err
	}
	out := hubDiagnosticsJSON{WindowDays: days, Rows: []hubDiagnosticsRowJSON{}}
	st, err := state.OpenReadOnly(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist): // no sidecar yet: no timings
	case err != nil:
		return err
	default:
		since := time.Now().Add(-time.Duration(days) * 24 * time.Hour)
		rows, err := st.LatencyStats(since)
		overflow, oerr := st.AlertPushOverflows(since)
		_ = st.Close()
		if err := errors.Join(err, oerr); err != nil {
			return err
		}
		for _, r := range rows {
			out.Rows = append(out.Rows, hubDiagnosticsRowJSON{
				Step: r.Step, Transport: r.Transport, P50Ms: r.P50.Milliseconds(), P90Ms: r.P90.Milliseconds(), Samples: r.Samples,
			})
		}
		out.PushOverflowExpired = overflow
	}
	if asJSON {
		return hubPrint(cmd, true, out, "")
	}
	lines := []string{fmt.Sprintf("hub timings, last %d day(s):", days)}
	if len(out.Rows) == 0 {
		lines = append(lines, "  no timings yet")
	}
	for _, r := range out.Rows {
		lines = append(lines, fmt.Sprintf("  %s on %s: p50 %d ms, p90 %d ms (%d samples)", r.Step, r.Transport, r.P50Ms, r.P90Ms, r.Samples))
	}
	if out.PushOverflowExpired > 0 {
		lines = append(lines, fmt.Sprintf("  %d alert push(es) dropped: too many waiting", out.PushOverflowExpired))
	}
	return hubPrint(cmd, false, nil, strings.Join(lines, "\n"))
}
