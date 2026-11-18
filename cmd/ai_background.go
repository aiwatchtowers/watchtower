package cmd

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"watchtower/internal/aiconsent"
	"watchtower/internal/config"
	"watchtower/internal/policy"
	"watchtower/internal/providers"
)

// backgroundRunsKey is the owner's answer in config.yaml. This command is
// its only writer; `config set` refuses it.
const backgroundRunsKey = "ai.background_runs"

// The `ai background` verbs read config and policy only: no database, so no
// schema-upgrade pre-run.
var aiBackgroundCmd = &cobra.Command{
	Use:               "background",
	Short:             "Allow or pause the AI Watchtower runs on its own",
	Long:              "Background AI is the AI work Watchtower starts on its own — on a timer, after a sync or on an event — not the work you start yourself. It stays paused until you allow it.",
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
}

var aiBackgroundStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show whether background AI may run, and who decided",
	Args:  cobra.NoArgs,
	RunE:  runAIBackgroundStatus,
}

var aiBackgroundAllowCmd = &cobra.Command{
	Use:   "allow",
	Short: "Let Watchtower run AI in the background",
	Args:  cobra.NoArgs,
	RunE:  runAIBackgroundAllow,
}

var aiBackgroundPauseCmd = &cobra.Command{
	Use:   "pause",
	Short: "Pause background AI (sync keeps running)",
	Args:  cobra.NoArgs,
	RunE:  runAIBackgroundPause,
}

var (
	aiBackgroundFlagJSON bool
	aiBackgroundFlagYes  bool
)

// backgroundConsentReader reads the consent state; nil = aiconsent.Current.
// Tests inject one that reads their temp config.
var backgroundConsentReader aiconsent.Reader

// signalDaemonFn wakes the running daemon after `allow` (test seam).
var signalDaemonFn = signalSyncNow

// stdinIsTTY reports whether `allow` may ask on a terminal (test seam).
var stdinIsTTY = func() bool { return term.IsTerminal(int(os.Stdin.Fd())) }

func init() {
	aiCmd.AddCommand(aiBackgroundCmd)
	aiBackgroundCmd.AddCommand(aiBackgroundStatusCmd, aiBackgroundAllowCmd, aiBackgroundPauseCmd)
	aiBackgroundStatusCmd.Flags().BoolVar(&aiBackgroundFlagJSON, "json", false, "output JSON")
	aiBackgroundAllowCmd.Flags().BoolVar(&aiBackgroundFlagYes, "yes", false, "allow without asking")
}

func readBackgroundConsent() aiconsent.State {
	if r := backgroundConsentReader; r != nil {
		return r()
	}
	return aiconsent.Current()
}

// aiBackgroundStatusJSON is `ai background status --json`; the keys are
// pinned (spec §9).
type aiBackgroundStatusJSON struct {
	Effective string `json:"effective"`
	Reason    string `json:"reason"`
	Answer    string `json:"answer"`
	Policy    *bool  `json:"policy"`
}

func runAIBackgroundStatus(cmd *cobra.Command, _ []string) error {
	s := readBackgroundConsent()
	if aiBackgroundFlagJSON {
		return json.NewEncoder(cmd.OutOrStdout()).Encode(aiBackgroundStatusJSON{
			Effective: string(s.Effective), Reason: string(s.Reason), Answer: string(s.Answer), Policy: s.Policy,
		})
	}
	_, err := fmt.Fprintln(cmd.OutOrStdout(), backgroundAIStatusLine(s))
	return err
}

// backgroundAIStatusLine is the `watchtower status` line (spec §9).
func backgroundAIStatusLine(s aiconsent.State) string {
	switch {
	case s.Allowed():
		return "Background AI: allowed"
	case s.Reason == aiconsent.ReasonOrganization:
		return "Background AI: turned off by your organization"
	case s.Reason == aiconsent.ReasonOwner:
		return "Background AI: paused by you"
	}
	return "Background AI: paused (not answered) — allow with `watchtower ai background allow`"
}

func runAIBackgroundAllow(cmd *cobra.Command, _ []string) error {
	if readBackgroundConsent().Locked {
		return fmt.Errorf("policy: background AI is %w (AllowBackgroundAI is false); nothing was written", policy.ErrNotAllowed)
	}
	if !aiBackgroundFlagYes && !stdinIsTTY() {
		return fmt.Errorf("background AI was not allowed: run with --yes to confirm")
	}
	// An explicit --workspace names the daemon to wake; it must be a plain
	// workspace name (no "/" or ".."), checked before anything is written. No
	// --workspace keeps a fresh install, with no workspace yet, able to answer.
	if flagWorkspace != "" && !config.ValidWorkspaceRe.MatchString(flagWorkspace) {
		return fmt.Errorf("invalid workspace name %q; nothing was written", flagWorkspace)
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	// The daemon to wake is the one of the workspace the command names (as
	// sync --now does).
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if !aiBackgroundFlagYes {
		ok, err := confirmBackgroundAI(cmd.InOrStdin(), cmd.OutOrStdout(), cfg)
		if err != nil {
			return err
		}
		if !ok {
			_, err := fmt.Fprintln(cmd.OutOrStdout(), "Nothing changed.")
			return err
		}
	}
	if err := setConfigKey(flagConfig, backgroundRunsKey, string(aiconsent.AnswerAllowed)); err != nil {
		return fmt.Errorf("saving the answer: %w", err)
	}
	// Best effort: a daemon that is not running, or cannot be signalled,
	// picks the answer up at its next cycle.
	if _, err := signalDaemonFn(cfg); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "Could not wake the daemon (%v); background AI starts at its next sync.\n", err)
	}
	_, err = fmt.Fprintln(cmd.OutOrStdout(), backgroundAIStatusLine(readBackgroundConsent()))
	return err
}

// runAIBackgroundPause is never refused: pausing is always the owner's to
// choose, whatever the organization's profile says.
func runAIBackgroundPause(cmd *cobra.Command, _ []string) error {
	if err := setConfigKey(flagConfig, backgroundRunsKey, string(aiconsent.AnswerPaused)); err != nil {
		return fmt.Errorf("saving the answer: %w", err)
	}
	_, err := fmt.Fprintln(cmd.OutOrStdout(), backgroundAIStatusLine(readBackgroundConsent()))
	return err
}

// confirmBackgroundAI prints the consent text for the configured agent and
// asks; anything but y/yes is no.
func confirmBackgroundAI(in io.Reader, out io.Writer, cfg *config.Config) (bool, error) {
	reserve := ""
	if cfg.AI.Fallback.Enabled {
		reserve = cfg.AI.Fallback.Provider
	}
	poll := max(1, int(cfg.Sync.PollInterval/time.Minute))
	if _, err := fmt.Fprintf(out, "%s\nAllow background AI? [y/N] ",
		consentText(cfg.AI.Provider, reserve, poll, cfg.Sync.BackfillDays)); err != nil {
		return false, err
	}
	// EOF (even with nothing typed) ends the answer; no answer is a no. Any
	// other read error is returned, never read as an answer.
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, fmt.Errorf("reading the answer: %w", err)
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true, nil
	}
	return false, nil
}

// subscriptionOf is the registry's plan facts of provider id; nil for an
// unknown id or a provider with no plan of the owner's.
func subscriptionOf(id string) *providers.Subscription {
	if p, ok := providers.Lookup(id); ok {
		return p.Subscription
	}
	return nil
}

// consentAgentName is the agent the consent text names (spec §5.1).
func consentAgentName(id string) string {
	if sub := subscriptionOf(id); sub != nil {
		return sub.AgentName
	}
	if name := providers.ByID(id).DisplayName; name != "" {
		return name
	}
	return id
}

// consentPlanName is the plan a subscription agent's runs draw on; "" for a
// provider with none.
func consentPlanName(id string) string {
	if sub := subscriptionOf(id); sub != nil {
		return sub.Plan
	}
	return ""
}

// consentText is the Go copy of the consent screen's text (spec §5.1), for
// `ai background allow` on a terminal. agent is the configured provider id;
// reserve is the automatic reserve's provider id, "" when it is off.
func consentText(agent, reserve string, pollMinutes, backfillDays int) string {
	name := consentAgentName(agent)
	var b strings.Builder
	b.WriteString("Let Watchtower run AI in the background?\n\n")
	b.WriteString("Watchtower uses " + name + " on this Mac to write your digests, briefings, tracks and people cards, " +
		"and to run your automations. Most of this starts on its own, on a schedule or after each sync, " +
		"without you asking each time.\n\n")
	sub := subscriptionOf(agent)
	if sub != nil {
		b.WriteString("These runs use " + sub.Usage + ". Watchtower never pays for, sees or shares your sign-in.\n")
	} else {
		b.WriteString("These runs use " + name + ", the model server set in Settings → AI.\n")
	}
	if plan := consentPlanName(reserve); plan != "" && sub != nil && reserve != agent {
		b.WriteString("When " + sub.Limit + " usage limit is reached, runs switch to " + consentAgentName(reserve) +
			" and use " + plan + ".\n")
	}
	b.WriteString("\nWhat can run on its own\n")
	for _, row := range []string{
		fmt.Sprintf("After each sync, about every %d min: channel digests, tracks, memory, next steps, image and link descriptions", pollMinutes),
		"Every few hours: ideas, Jira and mail digests",
		"Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching",
		fmt.Sprintf("After you connect a source: its last %d days of history, a little at each sync", backfillDays),
		"Your automations that use AI, at the times and on the events you set",
	} {
		b.WriteString("  • " + row + "\n")
	}
	b.WriteString("\nChats, Catch-Up, Run now and anything else you start yourself always run, whatever you pick here.\n")
	b.WriteString("You can change this any time in Settings → AI → Background AI.\n")
	return b.String()
}
