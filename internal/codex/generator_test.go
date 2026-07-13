package codex

import (
	"os/exec"
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
