package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/claude"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// connectionsImportCmd turns the MCP servers of the owner's own codex and
// Claude Code configs into Quick Connections (board #594): the codex chat
// no longer loads ~/.codex/config.toml's servers, so this is how they come
// back — mounted with the QC-02 read-only tool policy.
var connectionsImportCmd = &cobra.Command{
	Use:   "import [name...]",
	Short: "Import MCP servers from ~/.codex/config.toml and ~/.claude.json",
	Long: "Without names, lists the MCP servers found in your codex config\n" +
		"(CODEX_HOME/config.toml, else ~/.codex/config.toml) and your Claude Code\n" +
		"config (CLAUDE_CONFIG_DIR/.claude.json, else ~/.claude.json; user scope),\n" +
		"and why any of them cannot be imported. A variable a server names is read\n" +
		"from this environment, else from your login shell's.\n" +
		"With names, adds each as a Quick Connection — its env vars or headers go to\n" +
		"the connection's private secret file — and enables it, which lists its tools\n" +
		"(a server its config turned off is added disabled). An http server with no\n" +
		"headers that cannot list its tools needs an OAuth sign-in:\n" +
		"'watchtower connections oauth <id>'.",
	RunE: runConnectionsImport,
}

var connectionsImportFlagJSON bool

func init() {
	connectionsImportCmd.Flags().BoolVar(&connectionsImportFlagJSON, "json", false, "output JSON")
	connectionsCmd.AddCommand(connectionsImportCmd)
}

// connectionImportListJSON is `connections import --json` without names:
// the servers, the two files read (Sources) and how many servers the codex
// config declares (CodexServers, importable or not — the Desktop's codex
// notice shows only when there are some).
type connectionImportListJSON struct {
	Servers      []externalmcp.ImportCandidate `json:"servers"`
	Warnings     []string                      `json:"warnings"`
	Sources      importSourcesJSON             `json:"sources"`
	CodexServers int                           `json:"codex_servers"`
}

// importSourcesJSON names the files `connections import` reads.
type importSourcesJSON struct {
	Codex  string `json:"codex"`
	Claude string `json:"claude"`
}

func importSources() importSourcesJSON {
	return importSourcesJSON{Codex: filepath.Join(codex.OwnerHome(), "config.toml"), Claude: claudeConfigPath()}
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

// loginShellEnv is the owner's login shell environment, read once per
// process (claude.LoginShellEnv): the Desktop starts the CLI with a reduced
// environment. A var for tests.
var loginShellEnv = claude.LoginShellEnv

// importGetenv is os.Getenv, falling back to the login shell's environment.
func importGetenv(k string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return loginShellEnv()[k]
}

// importCandidates is what the owner's configs offer, each checked as
// `connections add` checks its flags and secret, with a server whose name
// is already a Quick Connection marked as such.
func importCandidates(database *db.DB) ([]externalmcp.ImportCandidate, []string, error) {
	src := importSources()
	cands, warnings := externalmcp.DiscoverImports(src.Codex, src.Claude, importGetenv)
	existing, err := database.ListExternalConnections()
	if err != nil {
		return nil, nil, fmt.Errorf("listing connections: %w", err)
	}
	for i, c := range cands {
		if c.Skip != "" {
			continue
		}
		if strings.EqualFold(c.Name, "watchtower") {
			cands[i].Skip = "it is Watchtower's own server"
		} else if err := validateImportCandidate(c); err != nil {
			cands[i].Skip = err.Error()
		} else if slices.ContainsFunc(existing, func(e db.ExternalConnection) bool { return strings.EqualFold(e.Name, c.Name) }) {
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

func validateImportCandidate(c externalmcp.ImportCandidate) error {
	if err := validateConnectionAddFlags(c.Name, c.Kind, c.Command, c.URL); err != nil {
		return err
	}
	return requireSecretTransport(c.Kind, c.URL, c.Secret)
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
			codexServers := 0
			for _, c := range cands {
				if c.Source == "codex" {
					codexServers++
				}
			}
			return writeJSON(out, connectionImportListJSON{Servers: cands, Warnings: warnings,
				Sources: importSources(), CodexServers: codexServers})
		}
		printImportCandidates(out, errOut, cands, warnings)
		return nil
	}
	results := importNames(out, errOut, cfg, database, cands, names)
	if connectionsImportFlagJSON {
		return writeJSON(out, results)
	}
	warnIfProviderIgnoresConnections(errOut, cfg, strings.Join(names, ", "))
	return nil
}

// importNames imports each name; in JSON mode the per-connection tool
// summaries are dropped, so stdout carries only the result array.
func importNames(out, errOut io.Writer, cfg *config.Config, database *db.DB, cands []externalmcp.ImportCandidate, names []string) []connectionImportResultJSON {
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
			res = connectionImportResultJSON{Name: name, Error: "not found in the codex or Claude Code config"}
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
	return results
}

// importConnection adds c as a connection with its secret in the 0600 file
// (the file needs the row's id, so the row is removed again when the secret
// cannot be saved), then enables it, which lists its tools — unless its
// source config turned it off.
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
			res.Error = fmt.Sprintf("saving secret: %v", err)
			if rmErr := database.RemoveExternalConnection(id); rmErr != nil {
				res.Error += fmt.Sprintf("; connection #%d was left without its secret and could not be removed: %v", id, rmErr)
				return res
			}
			res.ID = 0
			return res
		}
	}
	if !c.Enabled {
		res.Status = "disabled"
		return res
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
		fmt.Fprintln(out, "No MCP servers found in the codex or Claude Code config.")
		return
	}
	for _, c := range cands {
		fmt.Fprintln(out, importCandidateLine(c))
	}
	fmt.Fprintln(out, "Run 'watchtower connections import <name>...' to import.")
}

func importCandidateLine(c externalmcp.ImportCandidate) string {
	target := c.Command
	if c.Kind == "http" {
		target = c.URL
	}
	line := fmt.Sprintf("%s [%s, from %s] %s", c.Name, c.Kind, c.Source, target)
	if !c.Enabled {
		line += " (off in its config)"
	}
	if c.Note != "" {
		line += " — " + c.Note
	}
	if c.Skip != "" {
		line += " — cannot import: " + c.Skip
	}
	return line
}

func printImportResult(out io.Writer, r connectionImportResultJSON) {
	switch {
	case r.ID == 0:
		fmt.Fprintf(out, "%s: %s\n", r.Name, r.Error)
	case r.SignIn:
		fmt.Fprintf(out, "Imported %s as connection #%d; sign in with 'watchtower connections oauth %d'.\n", r.Name, r.ID, r.ID)
	case r.Status == "disabled":
		fmt.Fprintf(out, "Imported %s as connection #%d, disabled as in its config.\n", r.Name, r.ID)
	case r.Status != "ok":
		fmt.Fprintf(out, "Imported %s as connection #%d (%s).\n", r.Name, r.ID, r.Error)
	default:
		fmt.Fprintf(out, "Imported %s as connection #%d.\n", r.Name, r.ID)
	}
}
