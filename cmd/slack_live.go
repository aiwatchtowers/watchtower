package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/claude"
	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/slacklive"
)

var slackLiveCmd = &cobra.Command{
	Use:   "live",
	Short: "Slack Live: read Slack through your Claude or Codex connector",
}

var slackLiveProbeCmd = &cobra.Command{
	Use:   "probe",
	Short: "Check that a provider's Slack connector can really read",
	Long: "Makes one real read call through the provider's Slack connector and records\n" +
		"the verdict per workspace. --if-older D skips the call when a verdict for the\n" +
		"provider is newer than D (exit 0, skipped: true).",
	Args: cobra.NoArgs,
	RunE: runSlackLiveProbe,
}

func init() {
	slackLiveProbeCmd.Flags().String("provider", "claude", "claude or codex")
	slackLiveProbeCmd.Flags().Duration("if-older", 0, "skip when the provider's verdict is newer than this")
	slackLiveProbeCmd.Flags().Bool("json", false, "print the verdict as JSON")
	slackLiveCmd.AddCommand(slackLiveProbeCmd)
	slackCmd.AddCommand(slackLiveCmd)
}

// slackLiveJSON is the pinned output of `slack live probe --json`.
type slackLiveJSON struct {
	Provider    string   `json:"provider"`
	Status      string   `json:"status"`
	Teams       []string `json:"teams"`
	ErrorClass  string   `json:"error_class"`
	ConnectorID string   `json:"connector_id"`
	CheckedAt   string   `json:"checked_at"`
	Skipped     bool     `json:"skipped"`
}

// slackLiveBinary and slackLiveEnv are seams for the CLI test.
var (
	slackLiveBinary = func(provider string) string {
		if provider == "codex" {
			return codex.FindBinary("")
		}
		return claude.FindBinary("")
	}
	slackLiveEnv = func(provider string) []string {
		path := claude.RichPATH()
		if provider == "codex" {
			path = codex.RichPATH()
		}
		return append(os.Environ(), "PATH="+path)
	}
)

func runSlackLiveProbe(cmd *cobra.Command, _ []string) error {
	provider, _ := cmd.Flags().GetString("provider")
	if provider != "claude" && provider != "codex" {
		return fmt.Errorf("--provider must be claude or codex, got %q", provider)
	}
	ifOlder, _ := cmd.Flags().GetDuration("if-older")
	asJSON, _ := cmd.Flags().GetBool("json")
	_, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	now := time.Now()

	out := slackLiveJSON{Provider: provider, Teams: []string{}}
	if ifOlder > 0 {
		if rows, err := database.ListSlackLiveStatus(); err == nil {
			if fresh, ok := freshSlackLive(rows, provider, now, ifOlder); ok {
				out = fresh
			}
		}
	}
	if !out.Skipped {
		ctx, stop := signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)
		defer stop()
		r, err := slacklive.Check(ctx, database, provider, slackLiveBinary(provider), slackLiveEnv(provider), now)
		if err != nil {
			return fmt.Errorf("slack live probe: %w", err)
		}
		out = slackLiveJSON{Provider: provider, Status: r.Status, Teams: nonEmpty(r.Teams),
			ErrorClass: r.ErrorClass, ConnectorID: r.ConnectorID, CheckedAt: now.UTC().Format(time.RFC3339)}
	}
	w := cmd.OutOrStdout()
	if asJSON {
		return json.NewEncoder(w).Encode(out)
	}
	line := fmt.Sprintf("%s: %s", out.Provider, out.Status)
	if out.ErrorClass != "" {
		line += " (" + out.ErrorClass + ")"
	}
	if out.Skipped {
		line += " [recent, not re-checked]"
	}
	_, err = fmt.Fprintln(w, line)
	return err
}

// freshSlackLive returns the provider's newest verdict when it is younger
// than maxAge, shaped as a skipped result. rows come newest first.
func freshSlackLive(rows []db.SlackLiveStatus, provider string, now time.Time, maxAge time.Duration) (slackLiveJSON, bool) {
	var newest *db.SlackLiveStatus
	var teams []string
	for i := range rows {
		if rows[i].Provider != provider {
			continue
		}
		if newest == nil {
			newest = &rows[i]
		}
		if rows[i].CheckedAt.Equal(newest.CheckedAt) {
			teams = append(teams, rows[i].TeamID)
		}
	}
	if newest == nil || now.Sub(newest.CheckedAt) >= maxAge {
		return slackLiveJSON{}, false
	}
	connectorID := ""
	for _, r := range rows {
		if r.Provider == provider && r.ConnectorID != "" {
			connectorID = r.ConnectorID
			break
		}
	}
	return slackLiveJSON{Provider: provider, Status: newest.Status, Teams: nonEmpty(teams),
		ErrorClass: newest.ErrorClass, ConnectorID: connectorID,
		CheckedAt: newest.CheckedAt.UTC().Format(time.RFC3339), Skipped: true}, true
}

func nonEmpty(in []string) []string {
	out := []string{}
	for _, s := range in {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}
