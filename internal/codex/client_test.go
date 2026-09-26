package codex

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/digest"
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
	if stdin != "" {
		t.Errorf("stdin = %q, want empty for a short, no-dash message", stdin)
	}

	// Check required args are present.
	assertContains(t, args, "exec")
	assertContains(t, args, "--model")
	assertContains(t, args, "gpt-5.4")
	assertContains(t, args, "--json")
	assertContains(t, args, "--ephemeral")
	assertContains(t, args, "approval_policy=never")
	assertContains(t, args, "sandbox_mode=read-only")

	// System prompt passed via developer_instructions.
	found := false
	for _, a := range args {
		if a == "developer_instructions=you are a helper" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected developer_instructions arg with system prompt")
	}

	// User message should be the last argument.
	if args[len(args)-1] != "what is 2+2" {
		t.Errorf("last arg = %q, want user message", args[len(args)-1])
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
	args, _ := c.buildArgs("", "hello", "")

	// Should not contain developer_instructions when system prompt is empty.
	for _, a := range args {
		if a == "developer_instructions=" {
			t.Error("should not include developer_instructions with empty system prompt")
		}
	}
}

// TestClient_BuildArgs_LeadingDashGoesToStdin pins the leading-dash guard on
// promptPositionalOrStdin: a chat message beginning with '-' must never sit
// as the trailing positional (codex would parse it as a flag, not the
// prompt) even though it is far below digest.StdinThreshold.
func TestClient_BuildArgs_LeadingDashGoesToStdin(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	msg := "-v looks wrong"
	args, stdin := c.buildArgs("sys", msg, "")
	if stdin != msg {
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

// TestClient_BuildArgs_StdinThresholdBoundary pins the exact-threshold
// boundary so the inline and stdin routes never both fire: a message of
// exactly digest.StdinThreshold bytes stays inline, one byte over routes to
// stdin.
func TestClient_BuildArgs_StdinThresholdBoundary(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")

	exact := strings.Repeat("x", digest.StdinThreshold)
	args, stdin := c.buildArgs("sys", exact, "")
	if stdin != "" {
		t.Errorf("stdin = %d bytes, want empty: exactly StdinThreshold stays inline", len(stdin))
	}
	if len(args) == 0 || args[len(args)-1] != exact {
		t.Error("args must carry the exactly-threshold message as the last positional arg")
	}

	over := exact + "x"
	args2, stdin2 := c.buildArgs("sys", over, "")
	if stdin2 != over {
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
	dir, err := mcpWorkDir("/tmp/w.db", []string{"--chat", "--surface", "target"})
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
