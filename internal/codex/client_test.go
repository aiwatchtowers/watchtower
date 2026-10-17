package codex

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNewClient(t *testing.T) {
	c := NewClient("gpt-5.4", "/tmp/test.db", "/usr/local/bin/codex")
	if c.model != "gpt-5.4" {
		t.Errorf("model = %q, want %q", c.model, "gpt-5.4")
	}
	if c.dbPath != "/tmp/test.db" {
		t.Errorf("dbPath = %q, want %q", c.dbPath, "/tmp/test.db")
	}
}

func TestClient_BuildArgs(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	args, stdin := c.buildArgs("you are a helper", "what is 2+2", "")
	// Board #566: the prompts carry the owner's data and never sit on argv
	// (`ps`): the whole turn travels on stdin.
	if want := codexStdinContent("you are a helper", "what is 2+2"); stdin != want {
		t.Errorf("stdin = %q, want %q", stdin, want)
	}

	// Check required args are present.
	assertContains(t, args, "exec")
	assertContains(t, args, "--model")
	assertContains(t, args, "gpt-5.4")
	assertContains(t, args, "--json")
	assertContains(t, args, "--ephemeral")
	assertContains(t, args, "approval_policy=never")
	assertContains(t, args, "sandbox_mode=read-only")

	// Neither prompt is on argv; codex reads the turn from stdin ("-").
	for _, a := range args {
		if strings.Contains(a, "you are a helper") || strings.Contains(a, "what is 2+2") ||
			strings.HasPrefix(a, "developer_instructions=") {
			t.Errorf("args %v must carry no prompt text, found %q", args, a)
		}
	}
	if args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\"", args[len(args)-1])
	}

	// No --cd when workDir is empty.
	assertNotContains(t, args, "--cd")
}

func TestClient_BuildArgs_WithWorkDir(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	args, _ := c.buildArgs("sys", "msg", "/tmp/mcp-dir")

	assertContains(t, args, "--cd")
	assertContains(t, args, "/tmp/mcp-dir")
}

func TestClient_BuildArgs_NoSystemPrompt(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	args, stdin := c.buildArgs("", "hello", "")

	// Should not contain developer_instructions when system prompt is empty.
	for _, a := range args {
		if a == "developer_instructions=" {
			t.Error("should not include developer_instructions with empty system prompt")
		}
	}
	if strings.Contains(stdin, codexStdinSystemHeader) {
		t.Errorf("stdin = %q: no system section without a system prompt", stdin)
	}
}

// TestClient_BuildArgs_LeadingDashGoesToStdin: a chat message beginning
// with '-' never sits as the trailing positional either (codex would parse
// it as a flag, not the prompt).
func TestClient_BuildArgs_LeadingDashGoesToStdin(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	msg := "-v looks wrong"
	args, stdin := c.buildArgs("sys", msg, "")
	if !strings.HasSuffix(stdin, codexStdinUserHeader+msg) {
		t.Fatalf("stdin = %q, want the leading-dash message", stdin)
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\" (codex exec - reads the prompt from stdin)", args[len(args)-1])
	}
	for _, a := range args {
		if a == msg {
			t.Error("args contains the leading-dash message; it must travel via stdin only")
		}
	}
}

// TestClient_BuildArgs_StdinThresholdBoundary: there is no size threshold
// any more (board #566) — the 32 KiB message that used to be the largest
// positional travels on stdin like a larger one.
func TestClient_BuildArgs_StdinThresholdBoundary(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")

	exact := strings.Repeat("x", 32*1024)
	args, stdin := c.buildArgs("", exact, "")
	if stdin != codexStdinUserHeader+exact {
		t.Errorf("stdin = %d bytes, want the whole 32 KiB message", len(stdin))
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Error("args must end in \"-\", never carry the message")
	}

	over := exact + "x"
	args2, stdin2 := c.buildArgs("", over, "")
	if stdin2 != codexStdinUserHeader+over {
		t.Errorf("stdin length = %d, want the full over-threshold message", len(stdin2))
	}
	if len(args2) == 0 || args2[len(args2)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\"", args2[len(args2)-1])
	}
}

// TestQuerySync_LeadingDashMessageReachesStdin proves the leading-dash route
// wires all the way to the subprocess for QuerySync (one of the two call
// sites, :225): a fake codex binary reads its stdin and echoes a marker back
// only when it finds it there.
func TestQuerySync_LeadingDashMessageReachesStdin(t *testing.T) {
	const marker = "STDIN-MARKER-codex-client-sync-01"
	script := filepath.Join(t.TempDir(), "fake-codex")
	body := `#!/bin/sh
input=$(cat)
case "$input" in
*` + marker + `*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"got:` + marker + `"}}' ;;
*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"marker-missing"}}' ;;
esac
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := NewClient("gpt-5.4", "", script)
	msg := "-v " + marker
	out, _, err := c.QuerySync(context.Background(), "sys", msg, "")
	if err != nil {
		t.Fatalf("QuerySync error: %v", err)
	}
	if out != "got:"+marker {
		t.Errorf("output = %q, want %q — the leading-dash message did not reach the subprocess via stdin", out, "got:"+marker)
	}
}

// TestQuery_LeadingDashMessageReachesStdin is QuerySync's streaming sibling
// (the other call site, :106): the leading-dash route must also be wired on
// the Query call site.
func TestQuery_LeadingDashMessageReachesStdin(t *testing.T) {
	const marker = "STDIN-MARKER-codex-client-stream-02"
	script := filepath.Join(t.TempDir(), "fake-codex")
	body := `#!/bin/sh
input=$(cat)
case "$input" in
*` + marker + `*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"got:` + marker + `"}}' ;;
*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"marker-missing"}}' ;;
esac
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := NewClient("gpt-5.4", "", script)
	msg := "-v " + marker
	textCh, errCh, _ := c.Query(context.Background(), "sys", msg, "")

	var result strings.Builder
	for chunk := range textCh {
		result.WriteString(chunk.Text)
	}
	if err := <-errCh; err != nil {
		t.Fatalf("Query error: %v", err)
	}
	if result.String() != "got:"+marker {
		t.Errorf("result = %q, want %q — the leading-dash message did not reach the subprocess via stdin", result.String(), "got:"+marker)
	}
}

// TestChat04_CodexSessionArgvCarriesNoContent pins CHAT-04 (spec §9) for the
// chat session's codex backend (`ai session --provider codex`,
// cmd/ai_session.go): buildArgs must never emit the system prompt via
// -c developer_instructions=... nor place a short user message positionally
// — both must travel only on stdin, delimited so codex can still tell them
// apart. Since board #566 this holds for every client (cliGenerator, digest
// generators, plain `ai query`), not only the chat session's.
// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
func TestChat04_CodexSessionArgvCarriesNoContent(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")

	const sysSecret = "SYSTEM-PROMPT-SENTINEL-9f3a"
	const userSecret = "short owner message"
	args, stdin := c.buildArgs(sysSecret, userSecret, "")

	argv := strings.Join(args, "\x00")
	if strings.Contains(argv, sysSecret) {
		t.Errorf("argv %v must never carry the system prompt", args)
	}
	if strings.Contains(argv, userSecret) {
		t.Errorf("argv %v must never carry the user message", args)
	}
	assertNotContains(t, args, "developer_instructions="+sysSecret)
	assertContains(t, args, "-") // codex exec - reads the whole turn from stdin
	if args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\"", args[len(args)-1])
	}

	if !strings.Contains(stdin, sysSecret) {
		t.Errorf("stdin must carry the system prompt, got %q", stdin)
	}
	if !strings.Contains(stdin, userSecret) {
		t.Errorf("stdin must carry the user message, got %q", stdin)
	}
	if strings.Index(stdin, sysSecret) > strings.Index(stdin, userSecret) {
		t.Errorf("system instructions must come before the user message in stdin, got %q", stdin)
	}

	// A read-folder client (`ai query --read-folder`) keeps the same layout.
	c2 := NewClient("gpt-5.4", "", "codex")
	c2.SetReadFolder("/tmp/wd")
	args2, stdin2 := c2.buildArgs(sysSecret, userSecret, "/tmp/wd")
	if stdin2 != stdin {
		t.Errorf("stdin = %q, want the same delimited turn %q", stdin2, stdin)
	}
	if argv2 := strings.Join(args2, "\x00"); strings.Contains(argv2, sysSecret) || strings.Contains(argv2, userSecret) {
		t.Errorf("argv %v must never carry the prompts", args2)
	}
}

func assertContains(t *testing.T, args []string, want string) {
	t.Helper()
	for _, a := range args {
		if a == want {
			return
		}
	}
	t.Errorf("args %v should contain %q", args, want)
}

func assertNotContains(t *testing.T, args []string, unwanted string) {
	t.Helper()
	for _, a := range args {
		if a == unwanted {
			t.Errorf("args %v should not contain %q", args, unwanted)
			return
		}
	}
}

func TestMCPWorkDir_WritesExtraArgs(t *testing.T) {
	dir, err := mcpWorkDir("/tmp/w.db", []string{"--chat", "--surface", "target"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(dir) }()
	b, err := os.ReadFile(filepath.Join(dir, ".codex", "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `args = ["mcp", "--db-path", "/tmp/w.db", "--chat", "--surface", "target"]`) {
		t.Fatalf("config.toml = %s", b)
	}
}

// A no-tools run (`ai query --no-tools`, the ⌘/ help chat) mounts no MCP
// server even with a database path and turns web search off.
func TestClient_NoToolsMountsNothing(t *testing.T) {
	c := NewClient("gpt-5.4", "/tmp/test.db", "codex")
	c.SetNoTools()
	dir, cleanup, err := c.workDir()
	defer cleanup()
	if err != nil || dir != "" {
		t.Fatalf("workDir() = %q, %v; want no MCP dir", dir, err)
	}
	args := c.ArgsForTest("sys", "msg")
	assertContains(t, args, "mcp_servers={}")
	for _, a := range args {
		if (strings.Contains(a, "mcp_servers") && a != "mcp_servers={}") || strings.Contains(a, "/tmp/test.db") {
			t.Errorf("no-tools args mount an MCP server: %q in %v", a, args)
		}
	}
	assertNotContains(t, args, "--cd")
	assertContains(t, args, `web_search="disabled"`)
	assertContains(t, args, "features.shell_tool=false")
}
