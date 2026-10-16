package codex

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// mcpWorkDir creates a temporary directory with a .codex/config.toml that
// configures the watchtower MCP server — the watchtower binary itself run as
// `watchtower mcp --db-path <db>`, exposing curated read-only tools over stdio
// (no third-party npx package, no network). extra appends further flags to the
// server command — the chat mode flags (--chat --surface … --conversation …
// --turn …) the Desktop passes through `ai query --tools chat`; pass nil for
// the read-only dev server. The caller must remove the returned directory when
// done (typically via defer os.RemoveAll). envVars are passed through to the
// server (WatchtowerServerTOML); nil for every caller but an automation's
// agent() child.
// Returns the path to the temp directory and any error.
func mcpWorkDir(dbPath string, extra, envVars []string) (string, error) {
	tmpDir, err := os.MkdirTemp("", "codex-mcp-*")
	if err != nil {
		return "", fmt.Errorf("creating temp dir for codex MCP config: %w", err)
	}

	codexDir := filepath.Join(tmpDir, ".codex")
	if err := os.MkdirAll(codexDir, 0o755); err != nil {
		_ = os.RemoveAll(tmpDir)
		return "", fmt.Errorf("creating .codex dir: %w", err)
	}

	configContent := WatchtowerServerTOML(dbPath, extra, envVars)

	configPath := filepath.Join(codexDir, "config.toml")
	if err := os.WriteFile(configPath, []byte(configContent), 0o644); err != nil {
		_ = os.RemoveAll(tmpDir)
		return "", fmt.Errorf("writing codex MCP config: %w", err)
	}

	return tmpDir, nil
}

// WatchtowerServerTOML is the config.toml table that mounts this binary as
// codex's watchtower MCP server: `watchtower mcp --db-path <db> <extra…>`.
// envVars, when given, become the server's env_vars: codex starts MCP
// servers with a filtered environment, so a variable the server needs (an
// automation's run marker) must be named to reach it. With no envVars the
// table is the one the chat and dev servers always had.
func WatchtowerServerTOML(dbPath string, extra, envVars []string) string {
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	s := fmt.Sprintf("[mcp_servers.watchtower]\ncommand = %q\nargs = [%s]\n", watchtowerBinary(), quotedList(args))
	if len(envVars) > 0 {
		s += fmt.Sprintf("env_vars = [%s]\n", quotedList(envVars))
	}
	return s
}

// quotedList is items as the inside of a TOML string array.
func quotedList(items []string) string {
	quoted := make([]string, 0, len(items))
	for _, a := range items {
		quoted = append(quoted, strconv.Quote(a))
	}
	return strings.Join(quoted, ", ")
}

// mcpConfigOverrides mounts the same watchtower server as mcpWorkDir's
// config.toml, as `-c` overrides — for a run whose working root is not a
// temp dir (a read-folder run).
func mcpConfigOverrides(dbPath string, extra []string) []string {
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	return []string{
		"-c", "mcp_servers.watchtower.command=" + strconv.Quote(watchtowerBinary()),
		"-c", "mcp_servers.watchtower.args=[" + quotedList(args) + "]",
	}
}

// watchtowerBinary is the path used to relaunch this binary as an MCP server.
// In the desktop flow the running process IS the watchtower CLI (`ai query`),
// so os.Executable() is the correct self-path; fall back to a bare "watchtower"
// on the caller's PATH if it cannot be determined.
func watchtowerBinary() string {
	if exe, err := os.Executable(); err == nil && exe != "" {
		return exe
	}
	return "watchtower"
}
