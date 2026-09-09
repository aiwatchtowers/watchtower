package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// connectionNamePattern constrains --name to characters that are safe to
// comma-join into --allowedTools as mcp__<Name> (see buildArgs in
// internal/ai/client.go): an unconstrained name could inject an extra
// allowlist token (e.g. a comma) or otherwise break the server-key↔token
// match used to gate which external tools the model may call.
var connectionNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// connectionsCmd is the parent for the "Quick Connections" external MCP
// server family: add/list/enable/disable/remove, the slack.go account
// subcommand shape.
var connectionsCmd = &cobra.Command{
	Use:   "connections",
	Short: "Manage external MCP connections (Quick Connections)",
	Long: "Owner-managed external MCP servers whose read-only tools can be surfaced\n" +
		"in the assistant chat on demand. A connection is created disabled — the\n" +
		"owner enables it explicitly (per-connection consent).",
}

var connectionsAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a new external MCP connection (created disabled)",
	Long: "Inserts a new external_connections row, always disabled — the owner enables\n" +
		"it explicitly with 'connections enable'. With --secret-stdin, reads a JSON\n" +
		"object {\"env\":{...},\"headers\":{...}} from stdin and stores it via the\n" +
		"connection's SecretStore; the secret is never a flag/argv value.",
	RunE: runConnectionsAdd,
}

var connectionsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List external MCP connections",
	RunE:  runConnectionsList,
}

var connectionsEnableCmd = &cobra.Command{
	Use:   "enable <id>",
	Short: "Enable an external MCP connection",
	Args:  cobra.ExactArgs(1),
	RunE:  runConnectionsEnable,
}

var connectionsDisableCmd = &cobra.Command{
	Use:   "disable <id>",
	Short: "Disable an external MCP connection",
	Args:  cobra.ExactArgs(1),
	RunE:  runConnectionsDisable,
}

var connectionsRemoveCmd = &cobra.Command{
	Use:   "remove <id>",
	Short: "Remove an external MCP connection and its stored secret",
	Args:  cobra.ExactArgs(1),
	RunE:  runConnectionsRemove,
}

var (
	connectionsFlagJSON bool

	// connectionsAddCmd's flags are bound to package vars (the imapAddFlag*
	// precedent) rather than read via cmd.Flags().GetX — a *cobra.Command is
	// a package-level singleton reused by every test in this binary, and a
	// pflag StringArray in particular APPENDS on Set rather than replacing,
	// so tests must be able to reset these vars directly between runs.
	connectionsAddFlagName        string
	connectionsAddFlagKind        string
	connectionsAddFlagCommand     string
	connectionsAddFlagArgs        []string
	connectionsAddFlagURL         string
	connectionsAddFlagSecretStdin bool
)

func init() {
	connectionsAddCmd.Flags().StringVar(&connectionsAddFlagName, "name", "", "connection name (required)")
	connectionsAddCmd.Flags().StringVar(&connectionsAddFlagKind, "kind", "", `connection kind: "stdio" or "http" (required)`)
	connectionsAddCmd.Flags().StringVar(&connectionsAddFlagCommand, "command", "", "command to run (required for --kind stdio)")
	connectionsAddCmd.Flags().StringArrayVar(&connectionsAddFlagArgs, "arg", nil, "argument for the command (repeatable, stdio kind)")
	connectionsAddCmd.Flags().StringVar(&connectionsAddFlagURL, "url", "", "server URL (required for --kind http)")
	connectionsAddCmd.Flags().BoolVar(&connectionsAddFlagSecretStdin, "secret-stdin", false,
		`read a {"env":{...},"headers":{...}} JSON object from stdin and store it as this connection's secret`)

	connectionsListCmd.Flags().BoolVar(&connectionsFlagJSON, "json", false, "output JSON")

	connectionsCmd.AddCommand(connectionsAddCmd)
	connectionsCmd.AddCommand(connectionsListCmd)
	connectionsCmd.AddCommand(connectionsEnableCmd)
	connectionsCmd.AddCommand(connectionsDisableCmd)
	connectionsCmd.AddCommand(connectionsRemoveCmd)
	rootCmd.AddCommand(connectionsCmd)
}

// openConnectionsCmdDB is the shared preamble for the connections
// subcommands — the openSlackCmdDB/openJiraCmdDB precedent: loads config,
// applies the --workspace override, validates the workspace, and opens the
// database. The caller is responsible for closing the returned DB.
func openConnectionsCmdDB(_ *cobra.Command) (*config.Config, *db.DB, error) {
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
	return cfg, database, nil
}

// connectionJSON is the wire shape of one row for `connections list --json`.
type connectionJSON struct {
	ID        int64    `json:"id"`
	Name      string   `json:"name"`
	Kind      string   `json:"kind"`
	Command   string   `json:"command,omitempty"`
	Args      []string `json:"args,omitempty"`
	URL       string   `json:"url,omitempty"`
	Enabled   bool     `json:"enabled"`
	Status    string   `json:"status"`
	Error     string   `json:"error,omitempty"`
	CreatedAt string   `json:"created_at"`
}

func toConnectionJSON(c db.ExternalConnection) connectionJSON {
	return connectionJSON{ID: c.ID, Name: c.Name, Kind: c.Kind, Command: c.Command,
		Args: c.Args, URL: c.URL, Enabled: c.Enabled, Status: c.Status, Error: c.Error,
		CreatedAt: c.CreatedAt}
}

func runConnectionsAdd(cmd *cobra.Command, _ []string) error {
	name := connectionsAddFlagName
	kind := connectionsAddFlagKind
	command := connectionsAddFlagCommand
	args := connectionsAddFlagArgs
	url := connectionsAddFlagURL
	secretStdin := connectionsAddFlagSecretStdin

	if name == "" {
		return fmt.Errorf("--name is required")
	}
	if !connectionNamePattern.MatchString(name) {
		return fmt.Errorf("--name %q is invalid: must match %s (letters, digits, underscore, hyphen only)",
			name, connectionNamePattern.String())
	}
	if strings.EqualFold(name, "watchtower") {
		return fmt.Errorf(`--name "watchtower" is reserved (the built-in MCP server); choose another name`)
	}
	switch kind {
	case "stdio":
		if command == "" {
			return fmt.Errorf(`--command is required for --kind "stdio"`)
		}
	case "http":
		if url == "" {
			return fmt.Errorf(`--url is required for --kind "http"`)
		}
	default:
		return fmt.Errorf(`--kind must be "stdio" or "http" (got %q)`, kind)
	}

	// Parse the secret before touching the database, so a malformed
	// --secret-stdin payload never leaves behind a disabled row with no
	// secret to show for it.
	var secret *externalmcp.Secret
	if secretStdin {
		data, err := io.ReadAll(cmd.InOrStdin())
		if err != nil {
			return fmt.Errorf("reading secret from stdin: %w", err)
		}
		var sec externalmcp.Secret
		if err := json.Unmarshal(data, &sec); err != nil {
			return fmt.Errorf("parsing secret JSON from stdin: %w", err)
		}
		secret = &sec
	}

	cfg, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: name, Kind: kind, Command: command, Args: args, URL: url, Enabled: false,
	})
	if err != nil {
		return fmt.Errorf("creating connection: %w", err)
	}

	if secret != nil {
		if err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), id).Save(secret); err != nil {
			return fmt.Errorf("saving secret: %w", err)
		}
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Added connection #%d %q (%s), disabled.\n", id, name, kind)
	fmt.Fprintf(out, "Run 'watchtower connections enable %d' to enable it.\n", id)
	return nil
}

func runConnectionsList(cmd *cobra.Command, _ []string) error {
	_, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	conns, err := database.ListExternalConnections()
	if err != nil {
		return fmt.Errorf("listing connections: %w", err)
	}

	out := cmd.OutOrStdout()
	if connectionsFlagJSON {
		wire := make([]connectionJSON, 0, len(conns))
		for _, c := range conns {
			wire = append(wire, toConnectionJSON(c))
		}
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(wire)
	}

	if len(conns) == 0 {
		fmt.Fprintln(out, "No external connections configured.")
		fmt.Fprintln(out, "Run 'watchtower connections add' to add one.")
		return nil
	}
	for _, c := range conns {
		state := "enabled"
		if !c.Enabled {
			state = "disabled"
		}
		target := c.Command
		if c.Kind == "http" {
			target = c.URL
		}
		fmt.Fprintf(out, "#%d %s [%s] %s (%s) [%s]\n", c.ID, c.Name, c.Kind, target, c.Status, state)
	}
	return nil
}

func parseConnectionID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid connection id %q: %w", arg, err)
	}
	return id, nil
}

func runConnectionsEnable(cmd *cobra.Command, args []string) error {
	return setConnectionEnabled(cmd, args[0], true)
}

func runConnectionsDisable(cmd *cobra.Command, args []string) error {
	return setConnectionEnabled(cmd, args[0], false)
}

func setConnectionEnabled(cmd *cobra.Command, idArg string, enabled bool) error {
	id, err := parseConnectionID(idArg)
	if err != nil {
		return err
	}
	_, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.SetExternalConnectionEnabled(id, enabled); err != nil {
		return fmt.Errorf("updating connection: %w", err)
	}
	out := cmd.OutOrStdout()
	if enabled {
		fmt.Fprintf(out, "Connection %d enabled.\n", id)
	} else {
		fmt.Fprintf(out, "Connection %d disabled.\n", id)
	}
	return nil
}

func runConnectionsRemove(cmd *cobra.Command, args []string) error {
	id, err := parseConnectionID(args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.RemoveExternalConnection(id); err != nil {
		return fmt.Errorf("removing connection: %w", err)
	}
	if err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), id).Delete(); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to delete secret file for connection %d: %v\n", id, err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Removed connection %d.\n", id)
	return nil
}
