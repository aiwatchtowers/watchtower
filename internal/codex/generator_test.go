package codex

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/digest"
)

func TestNewCodexGenerator(t *testing.T) {
	gen := NewCodexGenerator("gpt-5.4", "/usr/local/bin/codex")
	if gen.model != "gpt-5.4" {
		t.Errorf("model = %q, want %q", gen.model, "gpt-5.4")
	}
	if gen.codexPath != "/usr/local/bin/codex" {
		t.Errorf("codexPath = %q, want %q", gen.codexPath, "/usr/local/bin/codex")
	}
}

func TestNewCodexGenerator_EmptyPath(t *testing.T) {
	gen := NewCodexGenerator(ModelDefault, "")
	if gen.model != ModelDefault {
		t.Errorf("model = %q, want %q", gen.model, ModelDefault)
	}
	if gen.codexPath != "" {
		t.Errorf("codexPath = %q, want empty", gen.codexPath)
	}
}

func TestCodexArgsSmallMessageInline(t *testing.T) {
	args, stdin := buildArgs("gpt-5.4", "sys", "hello")
	if stdin != "" {
		t.Errorf("stdin = %q, want empty for small message", stdin)
	}
	if len(args) == 0 || args[len(args)-1] != "hello" {
		t.Errorf("args = %v, want the message as the last positional arg", args)
	}
	foundSys := false
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-c" && strings.HasPrefix(args[i+1], "developer_instructions=") {
			foundSys = true
		}
	}
	if !foundSys {
		t.Errorf("args = %v, want -c developer_instructions=...", args)
	}
}

func TestCodexArgsLargeMessageViaStdin(t *testing.T) {
	big := strings.Repeat("x", digest.StdinThreshold+1)
	args, stdin := buildArgs("gpt-5.4", "sys", big)
	if stdin != big {
		t.Errorf("stdin length = %d, want the full message (%d bytes)", len(stdin), len(big))
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\" (codex exec - reads the prompt from stdin)", args[len(args)-1])
	}
	for _, a := range args {
		if a == big {
			t.Error("args contains the large message; it must travel via stdin only")
		}
	}
}

// TestCodexGeneratorLargeMessageReachesStdin proves the whole stdin wiring
// end-to-end: a fake codex binary (shell script) reads its stdin and echoes a
// marker back in the JSONL item.completed/agent_message format; the real CLI
// is never invoked because codexPath points at the script.
func TestCodexGeneratorLargeMessageReachesStdin(t *testing.T) {
	const marker = "STDIN-MARKER-codex-c0de"
	script := filepath.Join(t.TempDir(), "fake-codex")
	scriptBody := `#!/bin/sh
input=$(cat)
case "$input" in
*` + marker + `*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"got:` + marker + `"}}' ;;
*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"marker-missing"}}' ;;
esac
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake codex binary: %v", err)
	}

	gen := NewCodexGenerator("test-model", script)
	big := strings.Repeat("x", digest.StdinThreshold) + marker // > StdinThreshold → stdin path

	got, _, _, err := gen.Generate(context.Background(), "sys", big, "")
	if err != nil {
		t.Fatalf("Generate error: %v", err)
	}
	if got != "got:"+marker {
		t.Errorf("result = %q, want %q — the user message did not reach the subprocess via stdin", got, "got:"+marker)
	}
}

func TestCodexGeneratorHonorsDigestSource(t *testing.T) {
	script := filepath.Join(t.TempDir(), "fake-codex")
	scriptBody := `#!/bin/sh
echo '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake codex binary: %v", err)
	}

	gen := NewCodexGenerator("custom-model", script)

	_, usage, _, err := gen.Generate(context.Background(), "", "hello", "")
	if err != nil {
		t.Fatalf("Generate without source error: %v", err)
	}
	if usage == nil || usage.Model != "custom-model" {
		t.Fatalf("usage model without source = %#v, want custom-model", usage)
	}

	_, usage, _, err = gen.Generate(digest.WithSource(context.Background(), digest.SourceLight), "", "hello", "")
	if err != nil {
		t.Fatalf("Generate with source error: %v", err)
	}
	if usage == nil || usage.Model != ModelLightweight {
		t.Fatalf("usage model with light source = %#v, want %q", usage, ModelLightweight)
	}
}

func TestCodexArgsThresholdBoundary(t *testing.T) {
	exact := strings.Repeat("x", digest.StdinThreshold)
	args, stdin := buildArgs("gpt-5.4", "sys", exact)
	if stdin != "" {
		t.Errorf("stdin = %d bytes, want empty: exactly StdinThreshold stays inline", len(stdin))
	}
	if len(args) == 0 || args[len(args)-1] != exact {
		t.Error("args must carry the exactly-threshold message as the last positional arg")
	}
}

func TestClassifyError_NotFound(t *testing.T) {
	err := classifyError(&exec.Error{Name: "codex", Err: exec.ErrNotFound}, "", "/usr/bin/codex")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "codex CLI not found") {
		t.Errorf("error = %q, want to contain 'codex CLI not found'", err.Error())
	}
}

func TestClassifyError_ExitError(t *testing.T) {
	// We can't easily create a real exec.ExitError, so test the generic path.
	err := classifyError(exec.ErrDot, "", "/usr/bin/codex")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "codex CLI error") {
		t.Errorf("error = %q, want to contain 'codex CLI error'", err.Error())
	}
}

func TestClassifyError_WithStderr(t *testing.T) {
	// Generic error wrapping.
	err := classifyError(exec.ErrDot, "something went wrong", "/usr/bin/codex")
	if err == nil {
		t.Fatal("expected error")
	}
	// Generic errors don't use stderr, only ExitError does.
	if !strings.Contains(err.Error(), "codex CLI error") {
		t.Errorf("error = %q, want to contain 'codex CLI error'", err.Error())
	}
}

func TestLimitedWriter(t *testing.T) {
	var buf strings.Builder
	lw := &limitedWriter{w: &buf, limit: 5}

	n, err := lw.Write([]byte("hello world"))
	if err != nil {
		t.Fatalf("Write error: %v", err)
	}
	if n != 11 {
		t.Errorf("Write returned %d, want 11", n)
	}
	if buf.String() != "hello" {
		t.Errorf("buf = %q, want %q", buf.String(), "hello")
	}

	// Second write should be discarded.
	n, err = lw.Write([]byte("more"))
	if err != nil {
		t.Fatalf("Write error: %v", err)
	}
	if n != 4 {
		t.Errorf("Write returned %d, want 4", n)
	}
	if buf.String() != "hello" {
		t.Errorf("buf = %q, want %q", buf.String(), "hello")
	}
}
