package digest

import (
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
