package codex

import (
	"context"
	"os"
	"path/filepath"
	"slices"
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
	args, stdin := clientArgsT(t, c, "you are a helper", "what is 2+2", "")
	// Board #566: the prompts carry the owner's data and never sit on argv
	// (`ps`): the message travels on stdin, the system prompt in a 0600
	// model_instructions_file.
	if stdin != "what is 2+2" {
		t.Errorf("stdin = %q, want the user message", stdin)
	}
	if got := readInstructions(t, args); got != "you are a helper" {
		t.Errorf("instructions file = %q, want the system prompt", got)
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
	args, _ := clientArgsT(t, c, "sys", "msg", "/tmp/mcp-dir")

	assertContains(t, args, "--cd")
	assertContains(t, args, "/tmp/mcp-dir")
}

func TestClient_BuildArgs_NoSystemPrompt(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	args, stdin := clientArgsT(t, c, "", "hello", "")

	// Should not contain developer_instructions when system prompt is empty.
	for _, a := range args {
		if a == "developer_instructions=" {
			t.Error("should not include developer_instructions with empty system prompt")
		}
	}
	if path := instructionsFileOf(t, args); path != "" {
		t.Errorf("no system prompt, yet a model_instructions_file %q", path)
	}
	if stdin != "hello" {
		t.Errorf("stdin = %q, want the user message", stdin)
	}
}

// TestClient_BuildArgs_LeadingDashGoesToStdin: a chat message beginning
// with '-' never sits as the trailing positional either (codex would parse
// it as a flag, not the prompt).
func TestClient_BuildArgs_LeadingDashGoesToStdin(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")
	msg := "-v looks wrong"
	args, stdin := clientArgsT(t, c, "sys", msg, "")
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

// TestClient_BuildArgs_MessageOnStdinAtAnySize: there is no size threshold
// (board #566) — the 32 KiB message that used to be the largest positional
// travels on stdin like a larger one.
func TestClient_BuildArgs_MessageOnStdinAtAnySize(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")

	exact := strings.Repeat("x", 32*1024)
	args, stdin := clientArgsT(t, c, "", exact, "")
	if stdin != exact {
		t.Errorf("stdin = %d bytes, want the whole 32 KiB message", len(stdin))
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Error("args must end in \"-\", never carry the message")
	}

	over := exact + "x"
	args2, stdin2 := clientArgsT(t, c, "", over, "")
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

// TestChat04_CodexSessionArgvCarriesNoContent pins CHAT-04 (spec §9) for the
// chat session's codex backend (`ai session --provider codex`,
// cmd/ai_session.go): buildArgs must never emit the system prompt via
// -c developer_instructions=... nor place a short user message positionally:
// the system prompt reaches codex only through a 0600 model_instructions_file
// (its path is the one argv token) and the user message only on stdin. Since
// board #566 this holds for every client (cliGenerator, digest generators,
// plain `ai query`), not only the chat session's.
// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
func TestChat04_CodexSessionArgvCarriesNoContent(t *testing.T) {
	c := NewClient("gpt-5.4", "", "codex")

	const sysSecret = "SYSTEM-PROMPT-SENTINEL-9f3a"
	const userSecret = "short owner message"
	args, stdin := clientArgsT(t, c, sysSecret, userSecret, "")

	if argvCarries(args, sysSecret) {
		t.Errorf("argv %v must never carry the system prompt", args)
	}
	if argvCarries(args, userSecret) {
		t.Errorf("argv %v must never carry the user message", args)
	}
	assertNotContains(t, args, "developer_instructions="+sysSecret)
	assertContains(t, args, "-") // codex exec - reads the user message from stdin
	if args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\"", args[len(args)-1])
	}

	if got := readInstructions(t, args); got != sysSecret {
		t.Errorf("the model_instructions_file must carry the system prompt, got %q", got)
	}
	if stdin != userSecret {
		t.Errorf("stdin must carry the user message, got %q", stdin)
	}
	if strings.Contains(stdin, sysSecret) {
		t.Errorf("stdin must not repeat the system prompt, got %q", stdin)
	}

	// A read-folder client (`ai query --read-folder`) keeps the same layout.
	c2 := NewClient("gpt-5.4", "", "codex")
	c2.SetReadFolder("/tmp/wd")
	args2, stdin2 := clientArgsT(t, c2, sysSecret, userSecret, "/tmp/wd")
	if stdin2 != userSecret || readInstructions(t, args2) != sysSecret {
		t.Errorf("read-folder layout differs: stdin %q", stdin2)
	}
	if argvCarries(args2, sysSecret) || argvCarries(args2, userSecret) {
		t.Errorf("argv %v must never carry the prompts", args2)
	}
}

// TestQuerySync_SmallPromptsNeverReachArgv (board #566) runs the whole path
// through a fake codex binary: a small system prompt and a small user message
// — the common daemon case — never appear on its argv; the prompt arrives in
// the model_instructions_file and the message on stdin, and the file is gone
// once QuerySync returns.
func TestQuerySync_SmallPromptsNeverReachArgv(t *testing.T) {
	const sysMarker, userMarker = "SYS-MARKER-566", "USER-MARKER-566"
	script := filepath.Join(t.TempDir(), "fake-codex")
	useRealVersionProbe(t)
	body := `#!/bin/sh
[ "$1" = "--version" ] && { echo "codex-cli 0.145.0"; exit 0; }
reply() { echo '{"type":"item.completed","item":{"type":"agent_message","text":"'"$1"'"}}'; exit 0; }
case "$*" in *MARKER-566*) reply on-argv ;; esac
input=$(cat)
case "$input" in *` + userMarker + `*) ;; *) reply user-missing ;; esac
file=""
for a in "$@"; do
  case "$a" in model_instructions_file=*) file=${a#model_instructions_file=}; file=${file#\"}; file=${file%\"} ;; esac
done
if [ -n "$file" ] && grep -q ` + sysMarker + ` "$file"; then reply "ok|$file"; fi
reply sys-missing
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := NewClient("gpt-5.4", "", script)
	out, _, err := c.QuerySync(context.Background(), "sys "+sysMarker, "hello "+userMarker, "")
	if err != nil {
		t.Fatalf("QuerySync error: %v", err)
	}
	got, path, _ := strings.Cut(out, "|")
	if got != "ok" {
		t.Fatalf("output = %q, want ok: the prompts must travel by file and stdin, never argv", out)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Errorf("instructions file %q must be removed after the call, stat err = %v", path, statErr)
	}
}

func assertContains(t *testing.T, args []string, want string) {
	t.Helper()
	if slices.Contains(args, want) {
		return
	}
	t.Errorf("args %v should contain %q", args, want)
}

func assertNotContains(t *testing.T, args []string, unwanted string) {
	t.Helper()
	if slices.Contains(args, unwanted) {
		t.Errorf("args %v should not contain %q", args, unwanted)
		return
	}
}

func TestMCPOverride_WritesExtraArgs(t *testing.T) {
	got, _, _ := mcpOverride("/tmp/w.db", []string{"--chat", "--surface", "target"}, nil, nil, nil, nil)
	if !strings.Contains(got, `args=["mcp","--db-path","/tmp/w.db","--chat","--surface","target"]`) {
		t.Fatalf("override = %s", got)
	}
}
