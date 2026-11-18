package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/providers"
	"watchtower/internal/slackconnector"
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

// slackLiveBinary and slackLiveEnv are seams for the CLI test: the CLI the
// transport's probe runs and its environment.
var (
	slackLiveBinary = func(w *slackLiveWiring, cfg *config.Config) string { return w.binary(cfg) }
	slackLiveEnv    = func(w *slackLiveWiring) []string { return append(os.Environ(), "PATH="+w.path()) }
)

func runSlackLiveProbe(cmd *cobra.Command, _ []string) error {
	provider, _ := cmd.Flags().GetString("provider")
	live, ok := slackLiveFor(provider)
	if !ok {
		return fmt.Errorf("--provider must be one of %s, got %q", strings.Join(slackLiveProviders(), ", "), provider)
	}
	ifOlder, _ := cmd.Flags().GetDuration("if-older")
	asJSON, _ := cmd.Flags().GetBool("json")
	cfg, database, err := openSlackCmdDB()
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
		r, err := slacklive.Check(ctx, database, live.prepare(cfg), slackLiveBinary(live, cfg), slackLiveEnv(live), now)
		if err != nil {
			return fmt.Errorf("slack live probe: %w", err)
		}
		out = slackLiveJSON{Provider: provider, Status: r.Status, Teams: teamIDs(r.Teams),
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
// than maxAge, shaped as a skipped result. The verdict is the provider's
// newest probe batch (newestSlackLive); teams are the workspaces that check
// found ok (not the ones it recorded as absent).
func freshSlackLive(rows []db.SlackLiveStatus, provider string, now time.Time, maxAge time.Duration) (slackLiveJSON, bool) {
	newest, ok := newestSlackLive(rows, provider)
	if !ok || now.Sub(newest.CheckedAt) >= maxAge {
		return slackLiveJSON{}, false
	}
	var teams []string
	connectorID := ""
	for _, r := range rows {
		if r.Provider != provider {
			continue
		}
		if r.CheckedAt.Equal(newest.CheckedAt) && r.Status == slacklive.StatusOK {
			teams = append(teams, r.TeamID)
		}
		if connectorID == "" {
			connectorID = r.ConnectorID
		}
	}
	return slackLiveJSON{Provider: provider, Status: newest.Status, Teams: teamIDs(teams),
		ErrorClass: newest.ErrorClass, ConnectorID: connectorID,
		CheckedAt: newest.CheckedAt.UTC().Format(time.RFC3339), Skipped: true}, true
}

// teamIDs is the identified workspaces of a verdict: never nil (the JSON
// keeps []), without the ” row.
func teamIDs(in []string) []string {
	out := []string{}
	for _, s := range in {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// Error classes of a Slack Live verdict decided without a probe: the
// organization's policy (AllowClaudeAITools, AllowedAIProviders), the
// owner's claude.ai connectors switch, the claude.ai Slack connector switched
// off one by one.
const (
	slackLiveClassPolicy        = "policy"
	slackLiveClassConnectorsOff = "connectors_off"
	slackLiveClassDisabled      = "disabled"
)

// claudeSlackLiveOff is why the claude.ai Slack connector is off for every
// Watchtower child whatever a probe says (class for the status row, why for
// a run log); "" when it is not. Checked by the probe and by an automation
// agent() child on Live, as the chat's claudeSlackLiveChat checks it
// through its claude.ai mode.
func claudeSlackLiveOff(cfg *config.Config) (class, why string) {
	switch {
	case providers.Allowed("claude") != nil:
		return slackLiveClassPolicy, "the Claude provider is turned off by your organization's policy"
	case !policy.ClaudeAIToolsAllowed():
		return slackLiveClassPolicy, "claude.ai tools are turned off by your organization's policy"
	case !cfg.AI.ClaudeAI.Connectors:
		return slackLiveClassConnectorsOff, "claude.ai connectors are switched off in Settings"
	case chat.DisabledConnectorTokens(cfg.AI.ClaudeAI.DisabledConnectors)[slackconnector.ClaudeServer]:
		return slackLiveClassDisabled, "the claude.ai Slack connector is switched off in Settings"
	}
	return "", ""
}

// fixedSlackLiveVerdict is a probe that starts nothing and reports
// not_connected with class (Check writes it for every workspace, so an
// earlier ok does not outlive the switch).
func fixedSlackLiveVerdict(provider, status, class string) slacklive.Probe {
	return func(context.Context, string, []string) slacklive.Result {
		return slacklive.Result{Provider: provider, Status: status, ErrorClass: class}
	}
}

// claudeSlackLiveProbe is the Claude probe for cfg: a fixed verdict when the
// connector is off (claudeSlackLiveOff), else the real probe with its child
// in the chat's file sandbox; no sandbox fails closed (unavailable/sandbox,
// nothing started).
func claudeSlackLiveProbe(cfg *config.Config) slacklive.Probe {
	if class, _ := claudeSlackLiveOff(cfg); class != "" {
		return fixedSlackLiveVerdict("claude", slacklive.StatusNotConnected, class)
	}
	sandbox, err := aiSessionSandbox()
	if err != nil {
		fmt.Fprintf(os.Stderr, "slack live probe: no file sandbox: %v\n", err)
		return slacklive.ClaudeProbe(nil)
	}
	return slacklive.ClaudeProbe(sandbox.Command)
}

// codexSlackLiveProbe is the Codex probe: a fixed verdict when the
// organization's policy turns the Codex provider off.
func codexSlackLiveProbe(*config.Config) slacklive.Probe {
	if providers.Allowed("codex") != nil {
		return fixedSlackLiveVerdict("codex", slacklive.StatusNotConnected, slackLiveClassPolicy)
	}
	return slacklive.ProbeCodex
}
