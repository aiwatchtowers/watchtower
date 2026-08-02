package codex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMcpWorkDir_CreatesConfig(t *testing.T) {
	tmpDir, err := mcpWorkDir("/tmp/test.db")
	if err != nil {
		t.Fatalf("mcpWorkDir failed: %v", err)
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	configPath := filepath.Join(tmpDir, ".codex", "config.toml")
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("reading config.toml: %v", err)
	}

	content := string(data)
	if !strings.Contains(content, "[mcp_servers.watchtower]") {
		t.Error("config.toml should contain [mcp_servers.watchtower] section")
	}
	if !strings.Contains(content, "/tmp/test.db") {
		t.Error("config.toml should contain database path")
	}
	if !strings.Contains(content, `"mcp"`) || !strings.Contains(content, "--db-path") {
		t.Error("config.toml should launch `watchtower mcp --db-path`")
	}
	// The nonexistent npx sqlite package must be gone.
	if strings.Contains(content, "npx") || strings.Contains(content, "mcp-server-sqlite") {
		t.Error("config.toml must not reference the npx sqlite MCP package")
	}
}

func TestMcpWorkDir_DirectoryStructure(t *testing.T) {
	tmpDir, err := mcpWorkDir("/tmp/test.db")
	if err != nil {
		t.Fatalf("mcpWorkDir failed: %v", err)
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	// Check .codex dir exists.
	codexDir := filepath.Join(tmpDir, ".codex")
	info, err := os.Stat(codexDir)
	if err != nil {
		t.Fatalf(".codex dir should exist: %v", err)
	}
	if !info.IsDir() {
		t.Error(".codex should be a directory")
	}
}
