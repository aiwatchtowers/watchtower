package digest

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// containsPair reports whether args contains flag immediately followed by value.
func containsPair(args []string, flag, value string) bool {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

func TestGenerateArgsSmallMessageInline(t *testing.T) {
	args, stdin := generateArgs("m", "sys", "hello")
	if stdin != "" {
		t.Errorf("stdin = %q, want empty for small message", stdin)
	}
	if !containsPair(args, "-p", "hello") {
		t.Errorf("args = %v, want -p followed by the message", args)
	}
	if !containsPair(args, "--system-prompt", "sys") {
		t.Errorf("args = %v, want --system-prompt sys", args)
	}
	if !containsPair(args, "--model", "m") {
		t.Errorf("args = %v, want --model m", args)
	}
}

func TestGenerateArgsLargeMessageViaStdin(t *testing.T) {
	big := strings.Repeat("x", StdinThreshold+1)
	args, stdin := generateArgs("m", "sys", big)
	if stdin != big {
		t.Errorf("stdin length = %d, want the full message (%d bytes)", len(stdin), len(big))
	}
	// args must contain a bare "-p" NOT followed by the message: the next
	// token after "-p" must be a flag (starts with "--").
	pIdx := -1
	for i, a := range args {
		if a == "-p" {
			pIdx = i
			break
		}
	}
	if pIdx == -1 {
		t.Fatalf("args = %v, want a bare -p flag", args)
	}
	if pIdx+1 >= len(args) || !strings.HasPrefix(args[pIdx+1], "--") {
		t.Errorf("token after -p = %q, want a flag (message must not be inline)", args[pIdx+1])
	}
	for _, a := range args {
		if a == big {
			t.Error("args contains the large message; it must travel via stdin only")
		}
	}
}

// TestClaudeGeneratorLargeMessageReachesStdin proves the whole stdin wiring
// end-to-end: a fake claude binary (shell script) reads its stdin and echoes a
// marker back in the CLI's single-JSON-object output format; the real CLI is
// never invoked because claudePath points at the script.
func TestClaudeGeneratorLargeMessageReachesStdin(t *testing.T) {
	// Keep Generate's working directory (~/.config/watchtower) inside the test
	// sandbox instead of the real home.
	t.Setenv("HOME", t.TempDir())

	const marker = "STDIN-MARKER-claude-7f3a"
	script := filepath.Join(t.TempDir(), "fake-claude")
	scriptBody := `#!/bin/sh
input=$(cat)
case "$input" in
*` + marker + `*) echo '{"type":"result","result":"got:` + marker + `","is_error":false}' ;;
*) echo '{"type":"result","result":"marker-missing","is_error":false}' ;;
esac
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake claude binary: %v", err)
	}

	gen := NewClaudeGenerator("test-model-light", "test-model", script)
	big := strings.Repeat("x", StdinThreshold) + marker // > StdinThreshold → stdin path

	got, _, _, err := gen.Generate(context.Background(), "sys", big, "")
	if err != nil {
		t.Fatalf("Generate error: %v", err)
	}
	if got != "got:"+marker {
		t.Errorf("result = %q, want %q — the user message did not reach the subprocess via stdin", got, "got:"+marker)
	}
}

func TestGenerateArgsThresholdBoundary(t *testing.T) {
	exact := strings.Repeat("x", StdinThreshold)
	args, stdin := generateArgs("m", "sys", exact)
	if stdin != "" {
		t.Errorf("stdin = %d bytes, want empty: exactly StdinThreshold stays inline", len(stdin))
	}
	if !containsPair(args, "-p", exact) {
		t.Error("args must carry the exactly-threshold message inline after -p")
	}
}
