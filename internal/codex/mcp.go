package codex

import (
	"fmt"
	"os"
	"strconv"
)

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

// mcpConfigOverrides mounts the same watchtower server as newRunHome's
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
