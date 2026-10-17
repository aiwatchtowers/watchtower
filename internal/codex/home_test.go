package codex

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	toml "github.com/pelletier/go-toml/v2"

	"watchtower/internal/ai"
)

// recordingCodex is a fake codex that copies its CODEX_HOME's config.toml,
// the CODEX_HOME value, the auth.json link and its argv into dir, then
// answers.
func recordingCodex(t *testing.T, dir string) string {
	t.Helper()
	script := filepath.Join(dir, "fake-codex")
	body := "#!/bin/sh\n" +
		"cat >/dev/null\n" +
		"echo \"$CODEX_HOME\" > '" + dir + "/home'\n" +
		"cp \"$CODEX_HOME/config.toml\" '" + dir + "/config.toml'\n" +
		"readlink \"$CODEX_HOME/auth.json\" > '" + dir + "/auth-link'\n" +
		"for a in \"$@\"; do printf '%s\\n' \"$a\"; done > '" + dir + "/argv'\n" +
		`echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'` + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return script
}

// F1 (board #594): a chat run (a database path, the chat MCP flags) never
// reads the owner's ~/.codex/config.toml. It runs with its own CODEX_HOME
// whose config declares web search off, the watchtower server and the
// enabled Quick Connections (each limited to its allowed tools, its secret
// only in the 0600 file, never on argv), with the owner's sign-in linked;
// the home is gone after the run.
func TestChatRun_OwnCodexHome(t *testing.T) {
	owner := t.TempDir()
	t.Setenv("CODEX_HOME", owner)
	if err := os.WriteFile(filepath.Join(owner, "config.toml"), []byte("[mcp_servers.personal]\ncommand = \"/bin/false\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(owner, "auth.json"), []byte(`{"fake":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := t.TempDir()
	c := NewClient("gpt-5.4", "/tmp/w.db", recordingCodex(t, rec))
	c.SetMCPArgs([]string{"--chat", "--surface", "main"})
	c.SetStdinOnly(true)
	c.SetExternalMCPServers([]ai.ExternalMCPServer{
		{Name: "tracker", Kind: "stdio", Command: "npx", Args: []string{"-y", "tracker-mcp"},
			Env: map[string]string{"TRACKER_TOKEN": "s3cret-env"}, AllowTools: []string{"list_items"}, DenyTools: []string{"delete_item"}},
		{Name: "notes", Kind: "http", URL: "https://notes.example.com/mcp",
			Headers: map[string]string{"Authorization": "Bearer s3cret-hdr"}, AllowTools: []string{"get_note", "search_notes"}},
	})
	if _, _, err := c.QuerySync(context.Background(), "sys", "hello", ""); err != nil {
		t.Fatal(err)
	}

	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(rec, name))
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(b))
	}
	home := read("home")
	if home == "" || home == owner {
		t.Fatalf("CODEX_HOME = %q, want a per-run home, not the owner's %q", home, owner)
	}
	if _, err := os.Stat(home); !os.IsNotExist(err) {
		t.Errorf("the per-run home %s is left behind", home)
	}
	if got := read("auth-link"); got != filepath.Join(owner, "auth.json") {
		t.Errorf("auth.json link = %q, want the owner's sign-in", got)
	}
	argv := read("argv")
	for _, secret := range []string{"s3cret-env", "s3cret-hdr"} {
		if strings.Contains(argv, secret) {
			t.Errorf("argv carries a connection secret: %s", argv)
		}
	}

	var cfg struct {
		WebSearch  string `toml:"web_search"`
		MCPServers map[string]struct {
			Command      string            `toml:"command"`
			Args         []string          `toml:"args"`
			Env          map[string]string `toml:"env"`
			URL          string            `toml:"url"`
			HTTPHeaders  map[string]string `toml:"http_headers"`
			EnabledTools []string          `toml:"enabled_tools"`
		} `toml:"mcp_servers"`
	}
	raw := read("config.toml")
	if err := toml.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatalf("config.toml is not valid TOML: %v\n%s", err, raw)
	}
	if cfg.WebSearch != "disabled" {
		t.Errorf("web_search = %q, want disabled", cfg.WebSearch)
	}
	if len(cfg.MCPServers) != 3 {
		t.Fatalf("servers = %v, want watchtower + the two connections only", cfg.MCPServers)
	}
	wt := cfg.MCPServers["watchtower"]
	if strings.Join(wt.Args, " ") != "mcp --db-path /tmp/w.db --chat --surface main" {
		t.Errorf("watchtower args = %v", wt.Args)
	}
	tr := cfg.MCPServers["tracker"]
	if tr.Command != "npx" || strings.Join(tr.Args, " ") != "-y tracker-mcp" || tr.Env["TRACKER_TOKEN"] != "s3cret-env" ||
		strings.Join(tr.EnabledTools, ",") != "list_items" {
		t.Errorf("tracker = %+v", tr)
	}
	nt := cfg.MCPServers["notes"]
	if nt.URL != "https://notes.example.com/mcp" || nt.HTTPHeaders["Authorization"] != "Bearer s3cret-hdr" ||
		strings.Join(nt.EnabledTools, ",") != "get_note,search_notes" {
		t.Errorf("notes = %+v", nt)
	}
}

// A hostile string cannot break out of its TOML value.
func TestTomlString_Escapes(t *testing.T) {
	hostile := "a\"\nb = 1\n[mcp_servers.evil]\\\x01\xff"
	var got struct{ V string }
	if err := toml.Unmarshal([]byte("V = "+tomlString(hostile)+"\n"), &got); err != nil {
		t.Fatal(err)
	}
	if want := strings.ToValidUTF8(hostile, "�"); got.V != want {
		t.Errorf("round trip = %q, want %q", got.V, want)
	}
}
