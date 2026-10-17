package codex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The run's codex home (newRunHome, formerly the --cd folder's
// .codex/config.toml) mounts `watchtower mcp --db-path`.
func TestRunHome_CreatesConfig(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	tmpDir, err := newRunHome("/tmp/test.db", nil, nil, nil)
	if err != nil {
		t.Fatalf("newRunHome failed: %v", err)
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	configPath := filepath.Join(tmpDir, "config.toml")
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

// The home is private: it can hold a Quick Connection's secret.
func TestRunHome_DirectoryStructure(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	tmpDir, err := newRunHome("/tmp/test.db", nil, nil, nil)
	if err != nil {
		t.Fatalf("newRunHome failed: %v", err)
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	info, err := os.Stat(tmpDir)
	if err != nil {
		t.Fatalf("home dir should exist: %v", err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Errorf("home = %v, want a 0700 directory", info.Mode())
	}
	cfg, err := os.Stat(filepath.Join(tmpDir, "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Mode().Perm() != 0o600 {
		t.Errorf("config.toml mode = %v, want 0600", cfg.Mode().Perm())
	}
}

// An env var the server needs (an automation's run marker) is named in
// env_vars: codex starts MCP servers with a filtered environment. Without
// envVars the table carries no env_vars line.
func TestWatchtowerServerTOML_EnvVars(t *testing.T) {
	got := WatchtowerServerTOML("/tmp/w.db", []string{"--chat"}, []string{"WATCHTOWER_AUTOMATION_RUN_ID"})
	if !strings.HasSuffix(got, "args = [\"mcp\", \"--db-path\", \"/tmp/w.db\", \"--chat\"]\nenv_vars = [\"WATCHTOWER_AUTOMATION_RUN_ID\"]\n") {
		t.Fatalf("toml = %s", got)
	}
	if plain := WatchtowerServerTOML("/tmp/w.db", nil, nil); strings.Contains(plain, "env_vars") {
		t.Fatalf("toml without env vars = %s", plain)
	}
}
