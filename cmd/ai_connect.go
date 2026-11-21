package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/ai"
	"watchtower/internal/connectplay"
	"watchtower/internal/connectwire"
	"watchtower/internal/providers"
	"watchtower/internal/providers/caps"
)

// toolsConnect is `ai query --tools connect`: one turn of the Desktop's
// connect assistant (agent connect spec §5.2). The run mounts only
// `watchtower mcp --connect <service>`, whose socket and token ride the
// environment (connectwire.SocketEnv, TokenEnv); its system prompt is
// connectplay.SystemPrompt over the service's playbooks, then the
// Desktop's own (the current state).
const toolsConnect = "connect"

// checkConnectQuery checks the connect flags against --tools and returns
// the service's playbooks for a connect run (nil otherwise). A connect run
// reads no folder, saves no rows and takes no owner instructions: its
// prompt is a safety contract.
func checkConnectQuery(cmd *cobra.Command) ([]connectplay.Playbook, error) {
	f := cmd.Flags()
	if aiFlagTools != toolsConnect {
		if f.Changed("connect-service") || f.Changed("connect-mode") {
			return nil, errors.New("--connect-service and --connect-mode need --tools connect")
		}
		return nil, nil
	}
	for _, name := range []string{"read-folder", "read-folder-ask", "read-folder-round", "persist", "owner-instructions"} {
		if f.Changed(name) {
			return nil, fmt.Errorf("--tools connect runs without --%s", name)
		}
	}
	if m := connectplay.Mode(aiFlagConnectMode); m != connectplay.ModeBrowser && m != connectplay.ModeWords && !connectProbing() {
		return nil, fmt.Errorf("--connect-mode must be browser, words or probe, got %q", aiFlagConnectMode)
	}
	pbs, err := connectplay.ForService(aiFlagConnectService, "")
	if err != nil {
		return nil, fmt.Errorf("--connect-service: %w", err)
	}
	return pbs, nil
}

// connectModeProbe is `--connect-mode probe`: spike S1's probe turn (agent
// connect spec §10 "Task 0 outcome"). Before a browser run's first turn
// the Desktop asks whether the customer's browser extension is connected:
// the run has Claude in Chrome with list_connected_browsers as its only
// allowed tool, no built-in and no MCP server of ours (no connect tools,
// no socket, no token), and no playbook prompt.
const connectModeProbe = "probe"

func connectProbing() bool { return aiFlagConnectMode == connectModeProbe }

// connectProbeCheck refuses a probe on a provider whose agent cannot drive
// the browser, or one the organization's policy blocks.
func connectProbeCheck(provider string) error {
	if err := providers.Allowed(provider); err != nil {
		return err
	}
	if providers.CapsOf(provider).Connect != caps.ConnectBrowser {
		return providers.CapabilityError(provider, providers.ToolPreflight,
			fmt.Errorf("the %s provider has no browser to probe", providers.ByID(provider).ID))
	}
	return nil
}

// connectProbeEnv is the probe child's environment: environ (this process's),
// without the connect run's socket and token (the Desktop does not send
// them to a probe; a parent that has them keeps them to itself).
func connectProbeEnv(environ []string) []string {
	env := []string{} // never nil: nil would mean "inherit everything"
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if name != connectwire.SocketEnv && name != connectwire.TokenEnv {
			env = append(env, kv)
		}
	}
	return env
}

// connectGuides reports whether a provider's agent can guide a connection.
// Only browser and words do: none, and the zero row's "", do not.
func connectGuides(c providers.Capabilities) bool {
	return c.Connect == caps.ConnectBrowser || c.Connect == caps.ConnectWords
}

// connectRunMode is the mode a connect run on provider works in: browser
// only when --connect-mode asks for it and the provider's row has a
// browser, words otherwise. A provider that cannot guide, or that the
// organization's policy blocks, is refused.
func connectRunMode(provider string) (connectplay.Mode, error) {
	if err := providers.Allowed(provider); err != nil {
		return "", err
	}
	c := providers.CapsOf(provider)
	if !connectGuides(c) {
		return "", providers.CapabilityError(provider, providers.ToolPreflight,
			fmt.Errorf("the %s provider cannot guide a connection; set it up by hand or pick Claude or Codex", providers.ByID(provider).ID))
	}
	if connectplay.Mode(aiFlagConnectMode) == connectplay.ModeBrowser && c.Connect == caps.ConnectBrowser {
		return connectplay.ModeBrowser, nil
	}
	return connectplay.ModeWords, nil
}

// aiConnectGuardHosts are `ai connect-guard`'s --host values.
var aiConnectGuardHosts []string

// aiConnectGuardCmd is the PreToolUse hook a connect run's Claude in
// Chrome runs before each navigate (ai.Client.SetBrowser, spec §10 S2).
var aiConnectGuardCmd = &cobra.Command{
	Use:   "connect-guard",
	Short: "The connect run's navigate guard (a Claude Code PreToolUse hook)",
	Long: "Reads Claude Code's PreToolUse hook input on stdin and denies a navigate to a host outside\n" +
		"the --host list. It fails closed: input it cannot read is denied, and a denial it cannot\n" +
		"write exits 2, which Claude Code also reads as a denial. Every failure of this command\n" +
		"(a bad flag or argument included) exits 2: any other non-zero exit would let the call through.",
	Hidden: true,
	Args: func(_ *cobra.Command, args []string) error {
		if len(args) > 0 {
			return connectGuardFailure(fmt.Errorf("unexpected arguments %q", args))
		}
		return nil
	},
	// No root config pre-run: the hook reads nothing but stdin.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := runConnectGuard(cmd.InOrStdin(), cmd.OutOrStdout(), aiConnectGuardHosts); err != nil {
			return connectGuardFailure(err)
		}
		return nil
	},
}

// connectGuardFailure is a connect-guard failure as exit 2, Claude Code's
// blocking hook error: the navigation is refused.
func connectGuardFailure(err error) error {
	return &exitCodeError{code: 2, err: fmt.Errorf("connect-guard: navigation refused: %w", err)}
}

func init() {
	aiCmd.AddCommand(aiConnectGuardCmd)
	aiConnectGuardCmd.Flags().StringArrayVar(&aiConnectGuardHosts, "host", nil, "a host the browser may navigate to (repeatable)")
	aiConnectGuardCmd.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return connectGuardFailure(err) })
}

// connectGuardInputLimit bounds the hook input read.
const connectGuardInputLimit = 1 << 20

// runConnectGuard writes a PreToolUse denial to out unless the hook input
// on in is a navigate whose url connectplay.NavigationAllowed takes; the
// error is a denial it could not write.
func runConnectGuard(in io.Reader, out io.Writer, hosts []string) error {
	var input struct {
		ToolName  string `json:"tool_name"`
		ToolInput struct {
			URL string `json:"url"`
		} `json:"tool_input"`
	}
	data, err := io.ReadAll(io.LimitReader(in, connectGuardInputLimit))
	if err == nil {
		err = json.Unmarshal(data, &input)
	}
	switch {
	case err != nil || input.ToolName == "":
		return writeConnectGuardDenial(out, "Watchtower could not read this navigation, so it is refused. Ask the customer to open the page.")
	case input.ToolName != ai.BrowserNavigateTool:
		return nil // only navigate is guarded (the hook's matcher)
	case !connectplay.NavigationAllowed(input.ToolInput.URL, hosts):
		return writeConnectGuardDenial(out, fmt.Sprintf("This connect run stays on %s. Leave this page and stop.", strings.Join(hosts, ", ")))
	}
	return nil
}

func writeConnectGuardDenial(out io.Writer, reason string) error {
	var d preToolUseDenial
	d.HookSpecificOutput.HookEventName = "PreToolUse"
	d.HookSpecificOutput.PermissionDecision = "deny"
	d.HookSpecificOutput.PermissionDecisionReason = reason
	return json.NewEncoder(out).Encode(d)
}
