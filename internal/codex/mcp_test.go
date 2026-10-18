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
	content, _, _ := mcpOverride("/tmp/test.db", nil, nil, nil, nil, nil)
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
// Connection named like one is mounted under <name>-qc; an owner server
// named watchtower is disabled too and ours, enabled, takes a key no owner
// layer uses, so nothing of theirs (a url, enabled_tools, cwd, env) merges
// into it.
func TestMCPOverride_DisablesOwnerServers(t *testing.T) {
	got, _, _ := mcpOverride("/tmp/w.db", nil, nil,
		[]ai.ExternalMCPServer{{ID: 1, Name: "tracker", Kind: "stdio", Command: "npx", AllowTools: []string{"list_items"}}},
		[]string{"personal", "tracker", "watchtower"}, nil)
	servers := overrideServers(t, got)
	for _, name := range []string{"personal", "tracker", "watchtower"} {
		if len(servers[name]) != 1 || servers[name]["enabled"] != false {
			t.Errorf("owner server %s = %v, want only enabled=false", name, servers[name])
		}
	}
	if servers["tracker-qc"]["command"] != "npx" {
		t.Errorf("the connection is not mounted as tracker-qc: %s", got)
	}
	ours := servers["watchtower-app"]
	if ours["enabled"] != true || ours["command"] == nil || ours["url"] != nil {
		t.Errorf("watchtower-app = %v", ours)
	}
}

// The merged shape codex sees: the owner's [mcp_servers.watchtower] (an
// http server with its own tool filter) stays as written but off, and the
// key of ours appears in no owner layer, so the merge leaves it whole.
func TestMCPOverride_MergedWithAnOwnerWatchtower(t *testing.T) {
	ownerTOML := "[mcp_servers.watchtower]\nurl = \"https://mcp.example.com/mcp\"\nenabled_tools = [\"only_this\"]\n"
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(ownerTOML), 0o600); err != nil {
		t.Fatal(err)
	}
	owner, err := ownerServerNames(home, "")
	if err != nil {
		t.Fatal(err)
	}
	override, _, _ := mcpOverride("/tmp/w.db", nil, nil, nil, owner, nil)
	var file struct {
		MCPServers map[string]map[string]any `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal([]byte(ownerTOML), &file); err != nil {
		t.Fatal(err)
	}
	merged := file.MCPServers
	for key, fields := range overrideServers(t, override) {
		if merged[key] == nil {
			merged[key] = map[string]any{}
		}
		for k, v := range fields {
			merged[key][k] = v
		}
	}
	if merged["watchtower"]["enabled"] != false {
		t.Errorf("the owner's watchtower = %v, want it off", merged["watchtower"])
	}
	ours := merged["watchtower-app"]
	if ours["url"] != nil || ours["enabled_tools"] != nil || ours["enabled"] != true {
		t.Errorf("ours took owner fields: %v", ours)
	}
}

// Every layer codex 0.145 loads is scanned: CODEX_HOME, the system config
// and managed config, and each .codex/config.toml from the project root
// (the nearest project_root_markers ancestor) down to cwd — not above it.
func TestOwnerServerNames_AllLayers(t *testing.T) {
	home, sys, repo := t.TempDir(), t.TempDir(), t.TempDir()
	old := systemConfigDir
	SetSystemConfigDir(sys)
	t.Cleanup(func() { SetSystemConfigDir(old) })
	write := func(path, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	server := func(name string) string { return "[mcp_servers." + name + "]\ncommand = \"x\"\n" }
	write(filepath.Join(home, "config.toml"), "project_root_markers = [\".hg\"]\n"+server("home"))
	write(filepath.Join(sys, "config.toml"), server("system"))
	write(filepath.Join(sys, "managed_config.toml"), server("managed"))
	write(filepath.Join(repo, ".codex", "config.toml"), server("above_root"))
	root := filepath.Join(repo, "proj")
	write(filepath.Join(root, ".hg", "keep"), "")
	write(filepath.Join(root, ".codex", "config.toml"), server("root"))
	write(filepath.Join(root, "sub", ".codex", "config.toml"), server("sub"))
	cwd := filepath.Join(root, "sub", "deeper")
	if err := os.MkdirAll(cwd, 0o700); err != nil {
		t.Fatal(err)
	}
	got, err := ownerServerNames(home, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != "home,managed,root,sub,system" {
		t.Errorf("names = %v", got)
	}
}

func TestWatchtowerServerTOML_EnvVars(t *testing.T) {
	got := WatchtowerServerTOML("/tmp/w.db", []string{"--chat"}, []string{"WATCHTOWER_AUTOMATION_RUN_ID"})
	if !strings.HasSuffix(got, "args = [\"mcp\", \"--db-path\", \"/tmp/w.db\", \"--chat\"]\nenv_vars = [\"WATCHTOWER_AUTOMATION_RUN_ID\"]\n") {
		t.Fatalf("toml = %s", got)
	}
	if plain := WatchtowerServerTOML("/tmp/w.db", nil, nil); strings.Contains(plain, "env_vars") {
		t.Fatalf("toml without env vars = %s", plain)
	}
}

// The agent() child's server table pre-approves its tools: codex cancels
// any MCP call needing an approval under approval_policy=never, and an
// agent() call resolves to ask in Watchtower anyway (AGENT-03).
func TestWatchtowerServerTOML_ApprovesTools(t *testing.T) {
	var cfg struct {
		MCPServers map[string]map[string]any `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal([]byte(WatchtowerServerTOML("/tmp/w.db", nil, []string{"X"})), &cfg); err != nil {
		t.Fatal(err)
	}
	if got := cfg.MCPServers["watchtower"]["default_tools_approval_mode"]; got != "approve" {
		t.Errorf("default_tools_approval_mode = %v, want approve", got)
	}
}

// A connection with no allowed tool listed (nil or empty) is mounted with
// enabled_tools=[] — none of its tools — even though it is pre-approved.
func TestMCPOverride_NoAllowedToolsMountsNone(t *testing.T) {
	for _, allow := range [][]string{nil, {}} {
		got, _, _ := mcpOverride("/tmp/w.db", nil, nil,
			[]ai.ExternalMCPServer{{ID: 1, Name: "acme", Kind: "stdio", Command: "srv", AllowTools: allow}}, nil, nil)
		if !strings.Contains(got, `"acme"={command="srv",args=[],enabled_tools=[],default_tools_approval_mode="approve"}`) {
			t.Errorf("allow %#v: override = %s", allow, got)
		}
	}
}

// An env var the server needs (an automation's run marker) is named in
// env_vars: codex starts MCP servers with a filtered environment. Without
// envVars the table carries no env_vars.
func TestMCPOverride_EnvVars(t *testing.T) {
	got, _, _ := mcpOverride("/tmp/w.db", []string{"--chat"}, []string{"WATCHTOWER_AUTOMATION_RUN_ID"}, nil, nil, nil)
	if !strings.HasSuffix(got, `args=["mcp","--db-path","/tmp/w.db","--chat"],enabled=true,default_tools_approval_mode="approve",env_vars=["WATCHTOWER_AUTOMATION_RUN_ID"]}}`) {
		t.Fatalf("override = %s", got)
	}
	if plain, _, _ := mcpOverride("/tmp/w.db", nil, nil, nil, nil, nil); strings.Contains(plain, "env_vars") {
		t.Fatalf("override without env vars = %s", plain)
	}
}

// A connection whose env would change a variable codex reads itself (its
// network, TLS, runtime, loader or locations — any case) or one codex
// already holds is not mounted and is reported; two connections setting one
// variable differently mount only the first. Header variables are named
// after the connection id, so two http connections never clash.
func TestMCPOverride_EnvConflictsSkipTheConnection(t *testing.T) {
	ext := []ai.ExternalMCPServer{
		{ID: 1, Name: "a", Kind: "stdio", Command: "a", Env: map[string]string{"TOKEN": "1"}},
		{ID: 2, Name: "b", Kind: "stdio", Command: "b", Env: map[string]string{"TOKEN": "2"}},
		{ID: 3, Name: "c", Kind: "stdio", Command: "c", Env: map[string]string{"HOME": "/elsewhere"}},
		{ID: 4, Name: "d", Kind: "stdio", Command: "d", Env: map[string]string{"OPENAI_API_KEY": "k"}},
		{ID: 5, Name: "e", Kind: "stdio", Command: "e", Env: map[string]string{"ACME_REGION": "eu"}},
		{ID: 6, Name: "f", Kind: "http", URL: "https://f.example.com", Headers: map[string]string{"X": "1"}},
		{ID: 7, Name: "g", Kind: "http", URL: "https://g.example.com", Headers: map[string]string{"X": "2"}},
		{ID: 8, Name: "h", Kind: "http", URL: "https://h.example.com", Headers: map[string]string{"X": "3"}},
	}
	base := []string{"HOME=/home/acme", "ACME_REGION=eu", "WATCHTOWER_QC_8_0=already-set"}
	got, env, skipped := mcpOverride("/tmp/w.db", nil, nil, ext, nil, base)
	servers := overrideServers(t, got)
	for name, want := range map[string]bool{"a": true, "b": false, "c": false, "d": false, "e": true, "f": true, "g": true, "h": false} {
		if _, ok := servers[name]; ok != want {
			t.Errorf("%s mounted = %v, want %v (%s)", name, ok, want, got)
		}
	}
	if strings.Join(env, " ") != "TOKEN=1 ACME_REGION=eu WATCHTOWER_QC_6_0=1 WATCHTOWER_QC_7_0=2" {
		t.Errorf("env = %v", env)
	}
	if len(skipped) != 4 || !strings.Contains(skipped[2], "TOKEN") || !strings.Contains(skipped[8], "WATCHTOWER_QC_8_0") {
		t.Errorf("skipped = %v", skipped)
	}
	if again := EnvConflicts(ext, base); len(again) != 4 {
		t.Errorf("EnvConflicts = %v, want the same four", again)
	}
}

// Every variable codex reads itself is refused whatever its value, so a
// connection can never reconfigure the codex process.
func TestEnvConflicts_CodexOwnVariables(t *testing.T) {
	for i, k := range []string{"PATH", "https_proxy", "ALL_PROXY", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR",
		"RUST_LOG", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "TMPDIR", "XDG_CONFIG_HOME", "CODEX_HOME", "OPENAI_BASE_URL"} {
		got := EnvConflicts([]ai.ExternalMCPServer{{ID: int64(i + 1), Name: "s", Kind: "stdio", Command: "s", Env: map[string]string{k: "v"}}}, nil)
		if !strings.Contains(got[int64(i+1)], k) {
			t.Errorf("%s: not refused (%v)", k, got)
		}
	}
	if got := EnvConflicts([]ai.ExternalMCPServer{{ID: 1, Kind: "stdio", Env: map[string]string{"ACME_TOKEN": "v"}}}, nil); len(got) != 0 {
		t.Errorf("an ordinary variable is refused: %v", got)
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
	loads := 0
	c.SetExternalMCPLoader(func() []ai.ExternalMCPServer {
		loads++
		return []ai.ExternalMCPServer{
			{ID: 1, Name: "tracker", Kind: "stdio", Command: "npx", Args: []string{"-y", "tracker-mcp"},
				Env: map[string]string{"TRACKER_TOKEN": "s3cret-env"}, AllowTools: []string{"list_items"}, DenyTools: []string{"delete_item"}},
			{ID: 2, Name: "notes", Kind: "http", URL: "https://notes.example.com/mcp",
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
	// codex cancels an MCP call that needs an approval under
	// approval_policy=never: every mounted server is pre-approved.
	for _, name := range []string{"watchtower", "tracker", "notes"} {
		if servers[name]["default_tools_approval_mode"] != "approve" {
			t.Errorf("%s is not pre-approved: %v", name, servers[name])
		}
	}
	tr := servers["tracker"]
	if tr["command"] != "npx" || strings.Join(toStrings(tr["env_vars"]), ",") != "TRACKER_TOKEN" ||
		strings.Join(toStrings(tr["enabled_tools"]), ",") != "list_items" || tr["env"] != nil {
		t.Errorf("tracker = %v", tr)
	}
	nt := servers["notes"]
	hdrs, _ := nt["env_http_headers"].(map[string]any)
	if nt["url"] != "https://notes.example.com/mcp" || hdrs["Authorization"] != "WATCHTOWER_QC_2_0" ||
		strings.Join(toStrings(nt["enabled_tools"]), ",") != "get_note,search_notes" {
		t.Errorf("notes = %v", nt)
	}
}

// assertChatRunEnv: the secrets reach codex in its environment.
func assertChatRunEnv(t *testing.T, env string) {
	t.Helper()
	for _, kv := range []string{"TRACKER_TOKEN=s3cret-env", "WATCHTOWER_QC_2_0=Bearer s3cret-hdr"} {
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
