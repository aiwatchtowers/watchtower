package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
)

// The `tools` command group is the console analog of `watchtower mcp`: the
// same read-only data tools the MCP server exposes to LLM clients, callable
// directly from the terminal. It talks to the same tool registry through an
// in-process MCP session, so names, arguments, validation, and JSON output are
// identical to what an MCP client sees — and `tools list` / `tools describe`
// help is generated from the live tool schemas and can never drift from them.

var toolsCmd = &cobra.Command{
	Use:   "tools",
	Short: "Call Watchtower's read-only data tools from the console (analog of 'watchtower mcp')",
	Long: `Call Watchtower's read-only data tools from the console.

These are the same tools the MCP server ('watchtower mcp') exposes to LLM
clients (targets, briefings, digests, people, tracks, calendar, Jira), invoked
in-process with identical names, arguments, validation, and JSON output.
Everything is read-only.

Start with 'watchtower tools list' to see what is available, then
'watchtower tools describe <tool>' for its arguments.`,
	Example: `  # What tools exist?
  watchtower tools list

  # What arguments does a tool take?
  watchtower tools describe list_targets

  # Call a tool (arguments as key=value pairs)
  watchtower tools call list_targets status=todo limit=10
  watchtower tools call get_target id=42

  # Or pass arguments as a raw JSON object
  watchtower tools call list_digests --json '{"type":"channel","limit":5}'`,
}

var toolsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all available tools",
	Long: `List every available tool with a one-line description.

The list is read from the live tool registry, so it always matches what the
MCP server exposes.`,
	Args: cobra.NoArgs,
	RunE: runToolsList,
}

var toolsDescribeCmd = &cobra.Command{
	Use:   "describe <tool>",
	Short: "Show a tool's description and arguments",
	Long: `Show the full description of one tool and every argument it accepts:
name, type, whether it is required, and what it does.

The information is read from the tool's JSON schema — the same schema an MCP
client validates against.`,
	Example: `  watchtower tools describe list_targets
  watchtower tools describe get_digest`,
	Args: cobra.ExactArgs(1),
	RunE: runToolsDescribe,
}

var toolsCallJSON string

var toolsCallCmd = &cobra.Command{
	Use:   "call <tool> [key=value ...]",
	Short: "Call a tool and print its JSON result",
	Long: `Call one tool and print its JSON result to stdout.

Arguments are passed as key=value pairs and are converted to the types the
tool's schema declares (integer, boolean, number, string), or as one raw JSON
object via --json. Run 'watchtower tools describe <tool>' to see the accepted
arguments.

A tool-level failure (unknown id, invalid enum value, ...) exits non-zero with
the tool's error message.`,
	Example: `  watchtower tools call list_targets
  watchtower tools call list_targets status=todo priority=high limit=10
  watchtower tools call get_target id=42
  watchtower tools call list_jira_issues assignee=me
  watchtower tools call list_digests --json '{"type":"channel","limit":5}'`,
	Args: cobra.MinimumNArgs(1),
	RunE: runToolsCall,
}

func init() {
	toolsCallCmd.Flags().StringVar(&toolsCallJSON, "json", "",
		"tool arguments as a raw JSON object (instead of key=value pairs)")
	toolsCmd.AddCommand(toolsListCmd)
	toolsCmd.AddCommand(toolsDescribeCmd)
	toolsCmd.AddCommand(toolsCallCmd)
	rootCmd.AddCommand(toolsCmd)
}

// cmdContext returns the command's context, falling back to Background when
// the command was invoked without ExecuteContext (as tests do via RunE).
func cmdContext(cmd *cobra.Command) context.Context {
	if ctx := cmd.Context(); ctx != nil {
		return ctx
	}
	return context.Background()
}

// openToolSession opens the workspace DB read-only and connects an in-process
// MCP session over it — the same wiring as 'watchtower mcp' (cmd/mcp.go), so
// CLI calls run under identical read-only enforcement.
func openToolSession(cmd *cobra.Command) (*internalmcp.LocalSession, func(), error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	if err := database.SetReadOnly(); err != nil {
		database.Close()
		return nil, nil, fmt.Errorf("enforcing read-only: %w", err)
	}
	session, err := internalmcp.NewServer(database).ConnectLocal(cmdContext(cmd))
	if err != nil {
		database.Close()
		return nil, nil, fmt.Errorf("connecting tool session: %w", err)
	}
	cleanup := func() {
		_ = session.Close()
		database.Close()
	}
	return session, cleanup, nil
}

func runToolsList(cmd *cobra.Command, _ []string) error {
	session, cleanup, err := openToolSession(cmd)
	if err != nil {
		return err
	}
	defer cleanup()

	tools, err := session.Tools(cmdContext(cmd))
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	w := tabwriter.NewWriter(out, 2, 4, 2, ' ', 0)
	for _, t := range tools {
		fmt.Fprintf(w, "%s\t%s\n", t.Name, firstSentence(t.Description))
	}
	if err := w.Flush(); err != nil {
		return err
	}
	fmt.Fprintf(out, "\nRun 'watchtower tools describe <tool>' for arguments, 'watchtower tools call <tool> [key=value ...]' to call one.\n")
	return nil
}

func runToolsDescribe(cmd *cobra.Command, args []string) error {
	session, cleanup, err := openToolSession(cmd)
	if err != nil {
		return err
	}
	defer cleanup()

	tool, err := findTool(cmd, session, args[0])
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "%s\n\n%s\n", tool.Name, tool.Description)
	if len(tool.Args) == 0 {
		fmt.Fprintf(out, "\nArguments: none\n")
	} else {
		fmt.Fprintf(out, "\nArguments:\n")
		w := tabwriter.NewWriter(out, 2, 4, 2, ' ', 0)
		for _, a := range tool.Args {
			required := ""
			if a.Required {
				required = " (required)"
			}
			fmt.Fprintf(w, "  %s\t%s%s\t%s\n", a.Name, a.Type, required, a.Description)
		}
		if err := w.Flush(); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "\nExample:\n  watchtower tools call %s%s\n", tool.Name, exampleArgs(tool.Args))
	return nil
}

func runToolsCall(cmd *cobra.Command, args []string) error {
	session, cleanup, err := openToolSession(cmd)
	if err != nil {
		return err
	}
	defer cleanup()

	tool, err := findTool(cmd, session, args[0])
	if err != nil {
		return err
	}

	if toolsCallJSON != "" && len(args) > 1 {
		return fmt.Errorf("use either key=value arguments or --json, not both")
	}

	var callArgs map[string]any
	if toolsCallJSON != "" {
		if err := json.Unmarshal([]byte(toolsCallJSON), &callArgs); err != nil {
			return fmt.Errorf("--json must be a JSON object: %w", err)
		}
	} else {
		callArgs, err = coerceToolArgs(tool, args[1:])
		if err != nil {
			return err
		}
	}

	text, isToolErr, err := session.Call(cmdContext(cmd), tool.Name, callArgs)
	if err != nil {
		return fmt.Errorf("calling %s: %w", tool.Name, err)
	}
	if isToolErr {
		return fmt.Errorf("%s: %s", tool.Name, text)
	}
	fmt.Fprintln(cmd.OutOrStdout(), text)
	return nil
}

// findTool resolves a tool by name, or fails listing what exists.
func findTool(cmd *cobra.Command, session *internalmcp.LocalSession, name string) (internalmcp.ToolInfo, error) {
	tools, err := session.Tools(cmdContext(cmd))
	if err != nil {
		return internalmcp.ToolInfo{}, err
	}
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		if t.Name == name {
			return t, nil
		}
		names = append(names, t.Name)
	}
	return internalmcp.ToolInfo{}, fmt.Errorf(
		"unknown tool %q — available: %s (see 'watchtower tools list')",
		name, strings.Join(names, ", "))
}

// coerceToolArgs parses key=value pairs, converting each value to the type the
// tool's schema declares so typed tool handlers accept them.
func coerceToolArgs(tool internalmcp.ToolInfo, pairs []string) (map[string]any, error) {
	if len(pairs) == 0 {
		return nil, nil
	}
	byName := make(map[string]internalmcp.ToolArg, len(tool.Args))
	names := make([]string, 0, len(tool.Args))
	for _, a := range tool.Args {
		byName[a.Name] = a
		names = append(names, a.Name)
	}
	sort.Strings(names)

	out := make(map[string]any, len(pairs))
	for _, pair := range pairs {
		key, value, ok := strings.Cut(pair, "=")
		if !ok || key == "" {
			return nil, fmt.Errorf("argument %q is not key=value (see 'watchtower tools describe %s')", pair, tool.Name)
		}
		arg, known := byName[key]
		if !known {
			return nil, fmt.Errorf("%s takes no argument %q — accepted: %s", tool.Name, key, strings.Join(names, ", "))
		}
		switch arg.Type {
		case "integer":
			n, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("argument %s must be an integer, got %q", key, value)
			}
			out[key] = n
		case "number":
			f, err := strconv.ParseFloat(value, 64)
			if err != nil {
				return nil, fmt.Errorf("argument %s must be a number, got %q", key, value)
			}
			out[key] = f
		case "boolean":
			b, err := strconv.ParseBool(value)
			if err != nil {
				return nil, fmt.Errorf("argument %s must be true or false, got %q", key, value)
			}
			out[key] = b
		default:
			out[key] = value
		}
	}
	return out, nil
}

// firstSentence trims a description to its first sentence for the list view.
func firstSentence(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, ". "); i >= 0 {
		return s[:i+1]
	}
	return s
}

// exampleArgs renders a plausible call example from a tool's arguments:
// required args first with placeholder values, else the first optional one.
func exampleArgs(args []internalmcp.ToolArg) string {
	var b strings.Builder
	wrote := false
	for _, a := range args {
		if !a.Required {
			continue
		}
		fmt.Fprintf(&b, " %s=%s", a.Name, placeholderFor(a))
		wrote = true
	}
	if !wrote && len(args) > 0 {
		fmt.Fprintf(&b, " %s=%s", args[0].Name, placeholderFor(args[0]))
	}
	return b.String()
}

func placeholderFor(a internalmcp.ToolArg) string {
	switch a.Type {
	case "integer", "number":
		return "1"
	case "boolean":
		return "true"
	default:
		return "<" + a.Name + ">"
	}
}
