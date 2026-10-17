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

// overrideServers decodes a `mcp_servers={…}` override value.
func overrideServers(t *testing.T, override string) map[string]map[string]any {
	t.Helper()
	var cfg struct {
		MCPServers map[string]map[string]any `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal([]byte(override), &cfg); err != nil {
		t.Fatalf("override is not valid TOML: %v\n%s", err, override)
	}
	return cfg.MCPServers
}

// The override mounts `watchtower mcp --db-path`.
func TestMCPOverride_CreatesConfig(t *testing.T) {
	content, _ := mcpOverride("/tmp/test.db", nil, nil, nil, nil, nil)
	if !strings.Contains(content, `"watchtower"={`) {
		t.Error("override should contain the watchtower server")
	}
	if !strings.Contains(content, "/tmp/test.db") {
		t.Error("override should contain database path")
	}
	if !strings.Contains(content, `"mcp"`) || !strings.Contains(content, "--db-path") {
		t.Error("override should launch `watchtower mcp --db-path`")
	}
	// The nonexistent npx sqlite package must be gone.
	if strings.Contains(content, "npx") || strings.Contains(content, "mcp-server-sqlite") {
		t.Error("override must not reference the npx sqlite MCP package")
	}
}

// Every server of the owner's config layers is disabled; a Quick
// Connection named like one is mounted under <name>-qc so the two never
// merge; the owner's own "watchtower" is replaced, not disabled.
func TestMCPOverride_DisablesOwnerServers(t *testing.T) {
	got, _ := mcpOverride("/tmp/w.db", nil, nil,
		[]ai.ExternalMCPServer{{Name: "tracker", Kind: "stdio", Command: "npx", AllowTools: []string{"list_items"}}},
		[]string{"personal", "tracker", "watchtower"}, nil)
	servers := overrideServers(t, got)
	if servers["personal"]["enabled"] != false || servers["tracker"]["enabled"] != false {
		t.Errorf("owner servers not disabled: %s", got)
	}
	if servers["tracker-qc"]["command"] != "npx" {
		t.Errorf("the connection is not mounted as tracker-qc: %s", got)
	}
	if _, off := servers["watchtower"]["enabled"]; off || servers["watchtower"]["command"] == nil {
		t.Errorf("watchtower = %v", servers["watchtower"])
	}
}

// An env var the server needs (an automation's run marker) is named in
// env_vars: codex starts MCP servers with a filtered environment. Without
// envVars the table carries no env_vars.
func TestMCPOverride_EnvVars(t *testing.T) {
	got, _ := mcpOverride("/tmp/w.db", []string{"--chat"}, []string{"WATCHTOWER_AUTOMATION_RUN_ID"}, nil, nil, nil)
	if !strings.HasSuffix(got, `args=["mcp","--db-path","/tmp/w.db","--chat"],env_vars=["WATCHTOWER_AUTOMATION_RUN_ID"]}}`) {
		t.Fatalf("override = %s", got)
	}
	if plain, _ := mcpOverride("/tmp/w.db", nil, nil, nil, nil, nil); strings.Contains(plain, "env_vars") {
		t.Fatalf("override without env vars = %s", plain)
	}
}

// A connection whose env would change a variable codex already has (or one
// codex reads itself) is not mounted; two connections setting one variable
// differently mount only the first.
func TestMCPOverride_EnvConflictsSkipTheConnection(t *testing.T) {
	ext := []ai.ExternalMCPServer{
		{Name: "a", Kind: "stdio", Command: "a", Env: map[string]string{"TOKEN": "1"}},
		{Name: "b", Kind: "stdio", Command: "b", Env: map[string]string{"TOKEN": "2"}},
		{Name: "c", Kind: "stdio", Command: "c", Env: map[string]string{"HOME": "/elsewhere"}},
		{Name: "d", Kind: "stdio", Command: "d", Env: map[string]string{"OPENAI_API_KEY": "k"}},
		{Name: "e", Kind: "stdio", Command: "e", Env: map[string]string{"HOME": "/home/acme"}},
	}
	got, env := mcpOverride("/tmp/w.db", nil, nil, ext, nil, []string{"HOME=/home/acme"})
	servers := overrideServers(t, got)
	for name, want := range map[string]bool{"a": true, "b": false, "c": false, "d": false, "e": true} {
		if _, ok := servers[name]; ok != want {
			t.Errorf("%s mounted = %v, want %v (%s)", name, ok, want, got)
		}
	}
	if strings.Join(env, " ") != "TOKEN=1 HOME=/home/acme" {
		t.Errorf("env = %v", env)
	}
}

// A hostile string cannot break out of its TOML value.
func TestTOMLString_Escapes(t *testing.T) {
	hostile := "a\"\nb = 1\n[mcp_servers.evil]\\\x01\xff"
	var got struct{ V string }
	if err := toml.Unmarshal([]byte("V = "+TOMLString(hostile)+"\n"), &got); err != nil {
		t.Fatal(err)
	}
	if want := strings.ToValidUTF8(hostile, "�"); got.V != want {
		t.Errorf("round trip = %q, want %q", got.V, want)
	}
}

// recordingCodex is a fake codex that writes its CODEX_HOME, its argv and
// its environment into dir, then answers.
func recordingCodex(t *testing.T, dir string) string {
	t.Helper()
	script := filepath.Join(dir, "fake-codex")
	body := "#!/bin/sh\n" +
		"cat >/dev/null\n" +
		"echo \"$CODEX_HOME\" > '" + dir + "/home'\n" +
		"env > '" + dir + "/env'\n" +
		"for a in \"$@\"; do printf '%s\\n' \"$a\"; done > '" + dir + "/argv'\n" +
		`echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'` + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return script
}

// F1 (board #594): a chat run keeps the owner's CODEX_HOME (sign-in, model
// provider, profiles) but none of the owner's MCP servers: one -c override
// disables each of them and mounts the watchtower server and the enabled
// Quick Connections, each limited to its allowed tools. A connection's
// secret reaches codex only in the environment, named by env_vars /
// env_http_headers, never on argv. Web search stays the owner's setting.
// The loader runs per launch (QC-04).
func TestChatRun_MountsOnlyWatchtowerAndConnections(t *testing.T) {
	owner := t.TempDir()
	t.Setenv("CODEX_HOME", owner)
	if err := os.WriteFile(filepath.Join(owner, "config.toml"), []byte("[mcp_servers.personal]\ncommand = \"/bin/false\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := t.TempDir()
	c := NewClient("gpt-5.4", "/tmp/w.db", recordingCodex(t, rec))
	c.SetMCPArgs([]string{"--chat", "--surface", "main"})
	c.SetStdinOnly(true)
	loads := 0
	c.SetExternalMCPLoader(func() []ai.ExternalMCPServer {
		loads++
		return []ai.ExternalMCPServer{
			{Name: "tracker", Kind: "stdio", Command: "npx", Args: []string{"-y", "tracker-mcp"},
				Env: map[string]string{"TRACKER_TOKEN": "s3cret-env"}, AllowTools: []string{"list_items"}, DenyTools: []string{"delete_item"}},
			{Name: "notes", Kind: "http", URL: "https://notes.example.com/mcp",
				Headers: map[string]string{"Authorization": "Bearer s3cret-hdr"}, AllowTools: []string{"get_note", "search_notes"}},
		}
	})
	for range 2 {
		if _, _, err := c.QuerySync(context.Background(), "sys", "hello", ""); err != nil {
			t.Fatal(err)
		}
	}
	if loads != 2 {
		t.Errorf("connections loaded %d times, want once per launch", loads)
	}

	if got := readRec(t, rec, "home"); got != owner {
		t.Errorf("CODEX_HOME = %q, want the owner's %q", got, owner)
	}
	argv := readRec(t, rec, "argv")
	assertChatRunArgv(t, argv)
	assertChatRunServers(t, overrideServers(t, overrideIn(argv)))
	assertChatRunEnv(t, readRec(t, rec, "env"))
}

func readRec(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

// overrideIn is the mcp_servers override among argv lines.
func overrideIn(argv string) string {
	for _, a := range strings.Split(argv, "\n") {
		if strings.HasPrefix(a, "mcp_servers=") {
			return a
		}
	}
	return ""
}

// assertChatRunArgv: no secret on argv, web search untouched.
func assertChatRunArgv(t *testing.T, argv string) {
	t.Helper()
	for _, secret := range []string{"s3cret-env", "s3cret-hdr"} {
		if strings.Contains(argv, secret) {
			t.Errorf("argv carries a connection secret: %s", argv)
		}
	}
	if strings.Contains(argv, "web_search") {
		t.Errorf("the chat changes the owner's web search: %s", argv)
	}
}

// assertChatRunServers: the owner's server off, the watchtower server and
// the two connections limited to their allowed tools, secrets by name only.
func assertChatRunServers(t *testing.T, servers map[string]map[string]any) {
	t.Helper()
	if len(servers) != 4 || servers["personal"]["enabled"] != false {
		t.Fatalf("servers = %v, want personal disabled + watchtower + the two connections", servers)
	}
	if got := servers["watchtower"]["args"]; strings.Join(toStrings(got), " ") != "mcp --db-path /tmp/w.db --chat --surface main" {
		t.Errorf("watchtower args = %v", got)
	}
	tr := servers["tracker"]
	if tr["command"] != "npx" || strings.Join(toStrings(tr["env_vars"]), ",") != "TRACKER_TOKEN" ||
		strings.Join(toStrings(tr["enabled_tools"]), ",") != "list_items" || tr["env"] != nil {
		t.Errorf("tracker = %v", tr)
	}
	nt := servers["notes"]
	hdrs, _ := nt["env_http_headers"].(map[string]any)
	if nt["url"] != "https://notes.example.com/mcp" || hdrs["Authorization"] != "WATCHTOWER_QC_NOTES_0" ||
		strings.Join(toStrings(nt["enabled_tools"]), ",") != "get_note,search_notes" {
		t.Errorf("notes = %v", nt)
	}
}

// assertChatRunEnv: the secrets reach codex in its environment.
func assertChatRunEnv(t *testing.T, env string) {
	t.Helper()
	for _, kv := range []string{"TRACKER_TOKEN=s3cret-env", "WATCHTOWER_QC_NOTES_0=Bearer s3cret-hdr"} {
		if !strings.Contains(env, kv) {
			t.Errorf("child env lacks %s", kv)
		}
	}
}

func toStrings(v any) []string {
	items, _ := v.([]any)
	out := make([]string, 0, len(items))
	for _, it := range items {
		s, _ := it.(string)
		out = append(out, s)
	}
	return out
}
