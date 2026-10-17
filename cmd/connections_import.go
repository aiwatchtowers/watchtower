package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// connectionsImportCmd turns the MCP servers of the owner's own codex and
// Claude Code configs into Quick Connections (board #594): the codex chat
// no longer reads ~/.codex/config.toml, so this is how those servers come
// back — mounted with the QC-02 read-only tool policy.
var connectionsImportCmd = &cobra.Command{
	Use:   "import [name...]",
	Short: "Import MCP servers from ~/.codex/config.toml and ~/.claude.json",
	Long: "Without names, lists the MCP servers found in your codex config\n" +
		"(CODEX_HOME/config.toml, else ~/.codex/config.toml) and your Claude Code\n" +
		"config (~/.claude.json, user scope), and why any of them cannot be imported.\n" +
		"With names, adds each as a Quick Connection — its env vars or headers go to\n" +
		"the connection's private secret file — and enables it, which lists its tools.\n" +
		"An http server with no headers that cannot list its tools needs an OAuth\n" +
		"sign-in: 'watchtower connections oauth <id>'.",
	RunE: runConnectionsImport,
}

var connectionsImportFlagJSON bool

func init() {
	connectionsImportCmd.Flags().BoolVar(&connectionsImportFlagJSON, "json", false, "output JSON")
	connectionsCmd.AddCommand(connectionsImportCmd)
}

// connectionImportListJSON is `connections import --json` without names.
type connectionImportListJSON struct {
	Servers  []externalmcp.ImportCandidate `json:"servers"`
	Warnings []string                      `json:"warnings"`
}

// connectionImportResultJSON is one imported name. SignIn: an http server
// with no headers whose tools could not be listed — it likely needs
// `connections oauth <id>`.
type connectionImportResultJSON struct {
	Name   string `json:"name"`
	ID     int64  `json:"id,omitempty"`
	Status string `json:"status,omitempty"`
	Error  string `json:"error,omitempty"`
	SignIn bool   `json:"sign_in"`
}

// claudeConfigPath is Claude Code's user config: CLAUDE_CONFIG_DIR/.claude.json,
// else ~/.claude.json.
func claudeConfigPath() string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, ".claude.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude.json")
}

// importCandidates is what the owner's configs offer, with a server whose
// name is already a Quick Connection marked as such.
func importCandidates(database *db.DB) ([]externalmcp.ImportCandidate, []string, error) {
	cands, warnings := externalmcp.DiscoverImports(filepath.Join(codex.OwnerHome(), "config.toml"), claudeConfigPath(), os.Getenv)
	existing, err := database.ListExternalConnections()
	if err != nil {
		return nil, nil, fmt.Errorf("listing connections: %w", err)
	}
	for i, c := range cands {
		if c.Skip == "" && slices.ContainsFunc(existing, func(e db.ExternalConnection) bool { return strings.EqualFold(e.Name, c.Name) }) {
			cands[i].Skip = "a Quick Connection with this name already exists"
		}
	}
	if warnings == nil {
		warnings = []string{}
	}
	if cands == nil {
		cands = []externalmcp.ImportCandidate{}
	}
	return cands, warnings, nil
}

func runConnectionsImport(cmd *cobra.Command, names []string) error {
	cfg, database, err := openConnectionsCmdDB(cmd)
	if err != nil {
		return err
	}
	defer database.Close()
	cands, warnings, err := importCandidates(database)
	if err != nil {
		return err
	}
	out, errOut := cmd.OutOrStdout(), cmd.ErrOrStderr()
	if len(names) == 0 {
		if connectionsImportFlagJSON {
			return writeJSON(out, connectionImportListJSON{Servers: cands, Warnings: warnings})
		}
		printImportCandidates(out, errOut, cands, warnings)
		return nil
	}

	// In JSON mode the per-connection tool summaries are dropped: stdout
	// carries only the result array.
	toolsOut := out
	if connectionsImportFlagJSON {
		toolsOut = io.Discard
	}
	results := make([]connectionImportResultJSON, 0, len(names))
	for _, name := range names {
		i := slices.IndexFunc(cands, func(c externalmcp.ImportCandidate) bool { return c.Name == name })
		var res connectionImportResultJSON
		switch {
		case i < 0:
			res = connectionImportResultJSON{Name: name, Error: "not found in ~/.codex/config.toml or ~/.claude.json"}
		case cands[i].Skip != "":
			res = connectionImportResultJSON{Name: name, Error: "cannot import: " + cands[i].Skip}
		default:
			res = importConnection(toolsOut, errOut, cfg, database, cands[i])
		}
		results = append(results, res)
		if !connectionsImportFlagJSON {
			printImportResult(out, res)
		}
	}
	if connectionsImportFlagJSON {
		return writeJSON(out, results)
	}
	warnIfProviderIgnoresConnections(errOut, cfg, strings.Join(names, ", "))
	return nil
}

// importConnection adds c as a connection with its secret in the 0600 file
// (the file needs the row's id, so the row is removed again when the secret
// cannot be saved), then enables it, which lists its tools.
func importConnection(out, errOut io.Writer, cfg *config.Config, database *db.DB, c externalmcp.ImportCandidate) connectionImportResultJSON {
	res := connectionImportResultJSON{Name: c.Name}
	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: c.Name, Kind: c.Kind, Command: c.Command, Args: c.Args, URL: c.URL, Enabled: false,
	})
	if err != nil {
		res.Error = fmt.Sprintf("creating connection: %v", err)
		return res
	}
	res.ID = id
	if c.Secret != nil {
		if err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), id).Save(c.Secret); err != nil {
			_ = database.RemoveExternalConnection(id)
			return connectionImportResultJSON{Name: c.Name, Error: fmt.Sprintf("saving secret: %v", err)}
		}
	}
	if err := database.SetExternalConnectionEnabled(id, true); err != nil {
		res.Error = fmt.Sprintf("enabling connection: %v", err)
		return res
	}
	refreshToolsAfterEnable(out, errOut, cfg, database, id)
	if conn, err := database.GetExternalConnection(id); err == nil {
		res.Status, res.Error = conn.Status, conn.Error
	}
	res.SignIn = c.Kind == "http" && !c.HasSecret && res.Status != "ok"
	return res
}

func printImportCandidates(out, errOut io.Writer, cands []externalmcp.ImportCandidate, warnings []string) {
	for _, w := range warnings {
		fmt.Fprintf(errOut, "warning: %s\n", w)
	}
	if len(cands) == 0 {
		fmt.Fprintln(out, "No MCP servers found in ~/.codex/config.toml or ~/.claude.json.")
		return
	}
	for _, c := range cands {
		target := c.Command
		if c.Kind == "http" {
			target = c.URL
		}
		line := fmt.Sprintf("%s [%s, from %s] %s", c.Name, c.Kind, c.Source, target)
		if c.Skip != "" {
			line += " — cannot import: " + c.Skip
		}
		fmt.Fprintln(out, line)
	}
	fmt.Fprintln(out, "Run 'watchtower connections import <name>...' to import.")
}

func printImportResult(out io.Writer, r connectionImportResultJSON) {
	switch {
	case r.ID == 0:
		fmt.Fprintf(out, "%s: %s\n", r.Name, r.Error)
	case r.SignIn:
		fmt.Fprintf(out, "Imported %s as connection #%d; sign in with 'watchtower connections oauth %d'.\n", r.Name, r.ID, r.ID)
	case r.Status != "ok":
		fmt.Fprintf(out, "Imported %s as connection #%d (%s).\n", r.Name, r.ID, r.Error)
	default:
		fmt.Fprintf(out, "Imported %s as connection #%d.\n", r.Name, r.ID)
	}
}
