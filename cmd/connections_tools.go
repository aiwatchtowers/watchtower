package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"slices"

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
		"annotations — the name starts with get/list/search/read/fetch/query/find/\n" +
		"describe/lookup. Every other tool is hidden from the chat (QC-02).\n" +
		"--refresh re-lists the tools from the server; --allow replaces the default\n" +
		"with an explicit list of tool names; --default goes back to the default.",
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
		"allow exactly these tool names (comma-separated or repeated), replacing the read-only default")
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
		if err := database.SetExternalConnectionAllowTools(id, connectionsToolsFlagAllow); err != nil {
			return err
		}
		conn.AllowTools = connectionsToolsFlagAllow
		warnUnknownTools(cmd.ErrOrStderr(), conn)
	case connectionsToolsFlagDefault:
		if err := database.SetExternalConnectionAllowTools(id, nil); err != nil {
			return err
		}
		conn.AllowTools = nil
	}
	return printConnectionTools(cmd.OutOrStdout(), conn, connectionsToolsFlagJSON)
}

// listConnectionTools refreshes conn's cached tools/list from its server,
// with the same credentials a chat launch would use.
func listConnectionTools(cfg *config.Config, database *db.DB, conn *db.ExternalConnection) error {
	server, ok := connectionServer(cfg, database, *conn)
	if !ok {
		return fmt.Errorf("connection %d has no usable credentials (see the log; `connections oauth %d` to sign in again)", conn.ID, conn.ID)
	}
	return refreshConnectionTools(database, conn, server)
}

// refreshToolsAfterEnable lists a just-enabled (or just-signed-in)
// connection's tools and prints how many the chat may call. Best effort: on
// failure the connection stays enabled with no tool allowed (fail closed) and
// the next chat launch tries the listing again.
func refreshToolsAfterEnable(cmd *cobra.Command, cfg *config.Config, database *db.DB, id int64) {
	conn, err := database.GetExternalConnection(id)
	if err == nil {
		err = listConnectionTools(cfg, database, &conn)
	}
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(),
			"warning: could not list connection %d's tools (%v); none is available to the chat until a listing succeeds (`watchtower connections tools %d --refresh`)\n",
			id, err, id)
		return
	}
	allowed, _ := externalmcp.ResolveTools(conn)
	fmt.Fprintf(cmd.OutOrStdout(), "%d of %d tools available to the chat (read-only only; `watchtower connections tools %d` to review).\n",
		len(allowed), len(conn.Tools), id)
}

func warnUnknownTools(w io.Writer, conn db.ExternalConnection) {
	if !conn.ToolsListed {
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
	policy := "read-only tools only"
	if conn.AllowTools != nil {
		policy = "explicit list"
	}
	fmt.Fprintf(w, "Connection #%d %s: %d of %d tools allowed (%s), listed %s\n",
		conn.ID, conn.Name, len(allowed), len(conn.Tools), policy, conn.ToolsListedAt)
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
