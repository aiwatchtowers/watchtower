package digest

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
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

// fakeClaude writes a shell script that prints body on stdout and exits with
// code, standing in for the real CLI via the claudePath override.
func fakeClaude(t *testing.T, body string, code int) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "fake-claude")
	scriptBody := "#!/bin/sh\ncat >/dev/null\nprintf '%s' " + shellQuote(body) + "\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake claude binary: %v", err)
	}
	return script
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// TestClaudeGeneratorSurfacesEnvelopeErrorOnNonZeroExit pins the diagnostic
// contract for the CLI's own failures: it reports an API/usage error as an
// ordinary result envelope on stdout and exits 1, with the human-readable
// "result" sitting behind kilobytes of usage/telemetry JSON. Dumping that blob
// raw buries the one field a reader needs (and it is what the owner saw in the
// wild — the message truncated before "result" ever appeared).
func TestClaudeGeneratorSurfacesEnvelopeErrorOnNonZeroExit(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	// Field order mirrors the real CLI: result comes last, after usage.
	envelope := `[{"type":"system","subtype":"init","session_id":"s1"},` +
		`{"is_error":true,"duration_api_ms":59744,"num_turns":1,"stop_reason":"stop_sequence",` +
		`"session_id":"s1","total_cost_usd":0.003,` +
		`"usage":{"input_tokens":10,"cache_read_input_tokens":12174,"output_tokens":4},` +
		`"subtype":"error_during_execution","type":"result",` +
		`"result":"API Error: request was interrupted"}]`

	gen := NewClaudeGenerator("test-model", fakeClaude(t, envelope, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope")
	}
	if !strings.Contains(err.Error(), "API Error: request was interrupted") {
		t.Errorf("error = %q, want the CLI's own result message", err)
	}
	for _, diag := range []string{"stop_sequence", "error_during_execution"} {
		if !strings.Contains(err.Error(), diag) {
			t.Errorf("error = %q, want it to carry %q", err, diag)
		}
	}
	if strings.Contains(err.Error(), "cache_read_input_tokens") {
		t.Errorf("error = %q, want the raw envelope JSON kept out of it", err)
	}
}

// TestClaudeGeneratorEnvelopeErrorWithoutMessage covers the degenerate shape:
// a valid error envelope whose result string is empty still has to produce an
// error a reader can act on, not an empty tail.
func TestClaudeGeneratorEnvelopeErrorWithoutMessage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	envelope := `{"type":"result","subtype":"error_max_turns","is_error":true,"result":""}`
	gen := NewClaudeGenerator("test-model", fakeClaude(t, envelope, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope")
	}
	if !strings.Contains(err.Error(), "error_max_turns") {
		t.Errorf("error = %q, want the subtype to stand in for the missing message", err)
	}
}

// TestClaudeGeneratorUnparseableStdoutIsDescribedNotEchoed keeps the
// DescribeOutput doctrine on the failure path: stdout the parser cannot
// understand is model-derived text and must reach logs/UI as a fingerprint.
func TestClaudeGeneratorUnparseableStdoutIsDescribedNotEchoed(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	const secret = "acme-merger-with-globex-is-confidential"
	gen := NewClaudeGenerator("test-model", fakeClaude(t, secret, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for a failing CLI")
	}
	if strings.Contains(err.Error(), secret) {
		t.Errorf("error = %q, want the stdout content described, not echoed", err)
	}
	if !strings.Contains(err.Error(), "sha256:") {
		t.Errorf("error = %q, want a DescribeOutput fingerprint", err)
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

// TestGenerate_TierRoutingSelectsModel is ClaudeGenerator's sibling of the
// codex TestGenerate_TierRoutingHearsDigestSource pin: the source tag must
// route to the light/strong model end-to-end through Generate (a fake claude
// binary echoes back the --model value it received).
func TestGenerate_TierRoutingSelectsModel(t *testing.T) {
	script := filepath.Join(t.TempDir(), "claude")
	scriptBody := `#!/bin/sh
model=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--model" ]; then model="$a"; fi
  prev="$a"
done
echo "{\"type\":\"result\",\"result\":\"model:$model\",\"is_error\":false}"
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake claude binary: %v", err)
	}

	gen := NewClaudeGenerator("light-model", "strong-model", script)

	tests := []struct {
		name string
		ctx  context.Context
		want string
	}{
		{"untagged uses strong", context.Background(), "model:strong-model"},
		{"light source uses light", WithSource(context.Background(), "inbox.triage"), "model:light-model"},
		{"strong source uses strong", WithSource(context.Background(), "digest.channel"), "model:strong-model"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, _, _, err := gen.Generate(tt.ctx, "sys", "msg", "")
			if err != nil {
				t.Fatalf("Generate: %v", err)
			}
			if got != tt.want {
				t.Errorf("Generate = %q, want %q", got, tt.want)
			}
		})
	}
}
