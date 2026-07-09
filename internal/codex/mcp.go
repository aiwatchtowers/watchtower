package codex

import (
	"fmt"
	"os"
	"path/filepath"
)

// mcpWorkDir creates a temporary directory with a .codex/config.toml that
// configures the watchtower MCP server — the watchtower binary itself run as
// `watchtower mcp --db-path <db>`, exposing curated read-only tools over stdio
// (no third-party npx package, no network). The caller must remove the returned
// directory when done (typically via defer os.RemoveAll).
// Returns the path to the temp directory and any error.
func mcpWorkDir(dbPath string) (string, error) {
	tmpDir, err := os.MkdirTemp("", "codex-mcp-*")
	if err != nil {
		return "", fmt.Errorf("creating temp dir for codex MCP config: %w", err)
	}

	codexDir := filepath.Join(tmpDir, ".codex")
	if err := os.MkdirAll(codexDir, 0o755); err != nil {
		_ = os.RemoveAll(tmpDir)
		return "", fmt.Errorf("creating .codex dir: %w", err)
	}

	configContent := fmt.Sprintf(`[mcp_servers.watchtower]
command = %q
args = ["mcp", "--db-path", %q]
`, watchtowerBinary(), dbPath)

	configPath := filepath.Join(codexDir, "config.toml")
	if err := os.WriteFile(configPath, []byte(configContent), 0o644); err != nil {
		_ = os.RemoveAll(tmpDir)
		return "", fmt.Errorf("writing codex MCP config: %w", err)
	}

	return tmpDir, nil
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
