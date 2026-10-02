package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

var connectionsToolsCmd = &cobra.Command{
	Use:   "tools <id>",
	Short: "Show or change which of a connection's tools the chat may call",
	Long: "Lists the connection's tools (from its cached tools/list) and whether the\n" +
		"assistant chat may call each one. By default only tools known to be read-only\n" +
		"are allowed: the server annotates them readOnlyHint, or — when it gives no\n" +
		"annotations — the name starts with get/list/search/read/find/describe/\n" +
		"lookup with no later write word (create, update, delete, send, or…).\n" +
		"Every other tool is hidden from the chat (QC-02).\n" +
		"--refresh re-lists the tools from the server; --allow replaces the default\n" +
		"with an explicit list of tool names (never a tool the server marks as a write);\n" +
		"--default goes back to the default.",
	Args: cobra.ExactArgs(1),
	RunE: runConnectionsTools,
}

var (
	connectionsToolsFlagRefresh bool
	connectionsToolsFlagAllow   []string
	connectionsToolsFlagDefault bool
	connectionsToolsFlagJSON    bool
)

func init() {
	connectionsToolsCmd.Flags().BoolVar(&connectionsToolsFlagRefresh, "refresh", false, "re-list the tools from the server first")
	connectionsToolsCmd.Flags().StringSliceVar(&connectionsToolsFlagAllow, "allow", nil,
		"allow exactly these tool names (comma-separated or repeated), replacing the read-only default; a tool the server marks as a write is refused")
	connectionsToolsCmd.Flags().BoolVar(&connectionsToolsFlagDefault, "default", false,
		"drop the explicit list: allow only tools known to be read-only")
	connectionsToolsCmd.Flags().BoolVar(&connectionsToolsFlagJSON, "json", false, "output JSON")
	connectionsCmd.AddCommand(connectionsToolsCmd)
}

// connectionToolJSON is one row of `connections tools --json`.
type connectionToolJSON struct {
	Name     string `json:"name"`
	Allowed  bool   `json:"allowed"`
	ReadOnly bool   `json:"read_only"`
}

// connectionToolsJSON is the wire shape of `connections tools --json`.
type connectionToolsJSON struct {
	ID          int64                `json:"id"`
	Name        string               `json:"name"`
	Listed      bool                 `json:"listed"`
	ListedAt    string               `json:"listed_at,omitempty"`
	ExplicitSet bool                 `json:"explicit"`
	Tools       []connectionToolJSON `json:"tools"`
}

func runConnectionsTools(cmd *cobra.Command, args []string) error {
	id, err := parseConnectionID(args[0])
	if err != nil {
		return err
	}
	if connectionsToolsFlagDefault && connectionsToolsFlagAllow != nil {
		return fmt.Errorf("--allow and --default are mutually exclusive")
	}
	cfg, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()

	conn, err := database.GetExternalConnection(id)
	if err != nil {
		return err
	}
	if connectionsToolsFlagRefresh {
		if err := listConnectionTools(cfg, database, &conn); err != nil {
			return fmt.Errorf("listing tools: %w", err)
		}
	}
	switch {
	case connectionsToolsFlagAllow != nil:
		names, err := parseAllowList(connectionsToolsFlagAllow)
		if err != nil {
			return err
		}
		if err := refuseAnnotatedWrites(conn, names); err != nil {
			return err
		}
		if err := database.SetExternalConnectionAllowTools(id, names); err != nil {
			return err
		}
		conn.AllowTools = names
		warnUnknownTools(cmd.ErrOrStderr(), conn)
	case connectionsToolsFlagDefault:
		if err := database.SetExternalConnectionAllowTools(id, nil); err != nil {
			return err
		}
		conn.AllowTools = nil
	}
	if connectionsToolsFlagRefresh || connectionsToolsFlagAllow != nil || connectionsToolsFlagDefault {
		reconcileToolsStatus(database, conn)
	}
	return printConnectionTools(cmd.OutOrStdout(), conn, connectionsToolsFlagJSON)
}

// reconcileToolsStatus keeps the row's status in step with a changed tool
// policy: no allowed tool records the tools error; a usable policy clears a
// tools error this code wrote earlier (never a credential one).
func reconcileToolsStatus(database *db.DB, conn db.ExternalConnection) {
	allowed, _ := externalmcp.ResolveTools(conn)
	switch {
	case len(allowed) == 0:
		connectionUnmounted(database, conn, fmt.Sprintf(
			"none of its tools is available to the chat — `watchtower connections tools %d` to review", conn.ID))
	case conn.Status == "error" && strings.HasPrefix(conn.Error, toolsReasonPrefix):
		markConnectionOK(database, conn)
	}
}

// listConnectionTools refreshes conn's cached tools/list from its server,
// with the same credentials a chat launch would use.
func listConnectionTools(cfg *config.Config, database *db.DB, conn *db.ExternalConnection) error {
	server, ok := connectionServer(cfg, database, *conn)
	if !ok {
		return fmt.Errorf("%w (see the log; `connections oauth %d` to sign in again)", errNoCredentials, conn.ID)
	}
	return refreshConnectionTools(database, conn, server, toolsListTimeout)
}

// errNoCredentials: the connection's secret or OAuth grant is unusable; the
// row already says so (applyOAuthCredentials), so the tool policy leaves it.
var errNoCredentials = errors.New("no usable credentials")

// refreshToolsAfterEnable lists a just-enabled (or just-signed-in)
// connection's tools and reports how many the chat may call, on the row too
// (status "error" when none is) so Settings shows it — the Desktop ignores
// this command's output on success. Best effort: on a failed listing the
// connection stays enabled with no tool allowed (fail closed).
func refreshToolsAfterEnable(cmd *cobra.Command, cfg *config.Config, database *db.DB, id int64) {
	conn, err := database.GetExternalConnection(id)
	if err == nil {
		err = listConnectionTools(cfg, database, &conn)
	}
	if errors.Is(err, errNoCredentials) {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: connection %d: %v; none of its tools is available to the chat\n", id, err)
		return
	}
	if err != nil && !conn.ToolsListed {
		reason := fmt.Sprintf("listing its tools failed (%v); none is available to the chat — `watchtower connections tools %d --refresh`", err, id)
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: connection %d: %s\n", id, reason)
		connectionUnmounted(database, conn, reason)
		return
	}
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: connection %d: listing its tools failed (%v); the listing from %s still applies\n", id, err, conn.ToolsListedAt)
	}
	allowed, _ := externalmcp.ResolveTools(conn)
	if len(allowed) == 0 {
		reason := fmt.Sprintf("none of its tools is known read-only, so none is available to the chat — `watchtower connections tools %d` to review", id)
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: connection %d: %s\n", id, reason)
		connectionUnmounted(database, conn, reason)
		return
	}
	markConnectionOK(database, conn)
	fmt.Fprintf(cmd.OutOrStdout(), "%s. `watchtower connections tools %d` to review.\n", toolsSummary(conn, allowed), id)
}

// toolsSummary is the one-line "N tools available" sentence the CLI prints.
func toolsSummary(conn db.ExternalConnection, allowed []string) string {
	if conn.AllowTools != nil {
		return fmt.Sprintf("%d tools available to the chat (explicit list)", len(allowed))
	}
	return fmt.Sprintf("%d of %d tools available to the chat (read-only tools only)", len(allowed), len(conn.Tools))
}

// parseAllowList trims the --allow names and rejects an empty one: an empty
// name would render as the server-wide-looking token mcp__<name>__.
func parseAllowList(names []string) ([]string, error) {
	out := make([]string, 0, len(names))
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" {
			return nil, fmt.Errorf("--allow: empty tool name")
		}
		out = append(out, n)
	}
	return out, nil
}

// refuseAnnotatedWrites rejects an --allow list naming a tool the server's
// last listing annotates as a write: QC-02 keeps write tools out of the chat
// until external writes go through an Approve. ResolveTools enforces the same
// rule for names checked only after a later listing.
func refuseAnnotatedWrites(conn db.ExternalConnection, names []string) error {
	for _, t := range conn.Tools {
		if externalmcp.IsAnnotatedWrite(t) && slices.Contains(names, t.Name) {
			return fmt.Errorf("--allow: %q is a write tool (its server does not mark it read-only); write tools never reach the chat without an Approve step", t.Name)
		}
	}
	return nil
}

func warnUnknownTools(w io.Writer, conn db.ExternalConnection) {
	if !conn.ToolsListed {
		fmt.Fprintf(w, "warning: connection %d's tools were never listed, so these names are unchecked; any its server marks as a write will be denied once listed\n", conn.ID)
		return
	}
	for _, name := range conn.AllowTools {
		if !slices.ContainsFunc(conn.Tools, func(t db.ExternalTool) bool { return t.Name == name }) {
			fmt.Fprintf(w, "warning: %q is not in the server's last tool list\n", name)
		}
	}
}

func printConnectionTools(w io.Writer, conn db.ExternalConnection, asJSON bool) error {
	allowed, _ := externalmcp.ResolveTools(conn)
	wire := connectionToolsJSON{ID: conn.ID, Name: conn.Name, Listed: conn.ToolsListed,
		ListedAt: conn.ToolsListedAt, ExplicitSet: conn.AllowTools != nil, Tools: []connectionToolJSON{}}
	for _, t := range conn.Tools {
		wire.Tools = append(wire.Tools, connectionToolJSON{Name: t.Name,
			Allowed: slices.Contains(allowed, t.Name), ReadOnly: externalmcp.IsReadOnly(t)})
	}
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(wire)
	}
	if !conn.ToolsListed {
		fmt.Fprintf(w, "Connection #%d %s: tools never listed, so none is available to the chat.\n", conn.ID, conn.Name)
		fmt.Fprintf(w, "Run 'watchtower connections tools %d --refresh' to list them.\n", conn.ID)
		return nil
	}
	fmt.Fprintf(w, "Connection #%d %s: %s, listed %s\n", conn.ID, conn.Name, toolsSummary(conn, allowed), conn.ToolsListedAt)
	for _, t := range wire.Tools {
		mark, kind := "deny ", "not known read-only"
		if t.Allowed {
			mark = "allow"
		}
		if t.ReadOnly {
			kind = "read-only"
		}
		fmt.Fprintf(w, "  %s  %s (%s)\n", mark, t.Name, kind)
	}
	return nil
}
