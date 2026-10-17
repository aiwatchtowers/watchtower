package digest

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"watchtower/internal/config"
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

// A small message — the common daemon case — travels on stdin too, never
// after -p on argv, where every local process could read it through `ps`
// (board #566).
func TestGenerateArgsSmallMessageViaStdin(t *testing.T) {
	args, stdin := generateArgs("m", "", "hello")
	if stdin != "hello" {
		t.Errorf("stdin = %q, want the message", stdin)
	}
	if slices.Contains(args, "hello") {
		t.Errorf("args = %v carry the message", args)
	}
	if len(args) < 2 || args[0] != "-p" || !strings.HasPrefix(args[1], "--") {
		t.Errorf("args = %v, want a bare -p followed by a flag", args)
	}
	if slices.Contains(args, "--system-prompt") || slices.Contains(args, "--system-prompt-file") {
		t.Errorf("args = %v: no system prompt file, no system prompt flag", args)
	}
	if !containsPair(args, "--model", "m") {
		t.Errorf("args = %v, want --model m", args)
	}
}

func TestGenerateArgsLargeMessageViaStdin(t *testing.T) {
	big := strings.Repeat("x", 64*1024+1)
	args, stdin := generateArgs("m", "", big)
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
	big := strings.Repeat("x", 64*1024) + marker // well past a single argv value's limit

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

	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, envelope, 1))

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
	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, envelope, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope")
	}
	if !strings.Contains(err.Error(), "error_max_turns") {
		t.Errorf("error = %q, want the subtype to stand in for the missing message", err)
	}
}

// TestClaudeGeneratorEnvelopeErrorOnZeroExit covers the sibling of the
// non-zero-exit path: the CLI can flag is_error and still exit 0, and that
// branch reads the same envelope, so it needs the same treatment — a missing
// message must not leave an empty tail here either.
func TestClaudeGeneratorEnvelopeErrorOnZeroExit(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	envelope := `{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}`
	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, envelope, 0))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope on exit 0")
	}
	if !strings.Contains(err.Error(), "error_during_execution") {
		t.Errorf("error = %q, want the subtype to stand in for the missing message", err)
	}
	if strings.HasSuffix(err.Error(), ": ") {
		t.Errorf("error = %q, want a message rather than an empty tail", err)
	}
}

// TestClaudeGeneratorEnvelopeMessageIsBounded keeps a runaway envelope out of
// the logs: on subtype=error_max_turns the result field carries the model's own
// partial output, which is unbounded where the sibling stderr path is capped.
func TestClaudeGeneratorEnvelopeMessageIsBounded(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	huge := strings.Repeat("x", 200_000)
	envelope := `{"type":"result","subtype":"error_max_turns","is_error":true,"result":"` + huge + `"}`
	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, envelope, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope")
	}
	if len(err.Error()) > 8192 {
		t.Errorf("error length = %d, want the envelope message bounded", len(err.Error()))
	}
	if !strings.Contains(err.Error(), "truncated") {
		t.Errorf("error = %q, want the truncation stated rather than silent", err)
	}
}

// TestClaudeGeneratorEnvelopeTruncationKeepsValidUTF8 pins the rune backoff:
// this text is model output and routinely Cyrillic, so a cut on a byte index
// lands mid-rune. An ASCII-only truncation test passes with the backoff deleted.
func TestClaudeGeneratorEnvelopeTruncationKeepsValidUTF8(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	// THREE bytes per rune, deliberately: 4096 % 3 == 1, so the cap lands one
	// byte inside a rune and a naive slice produces invalid UTF-8. (A 2-byte
	// fill would put byte 4096 exactly on a boundary and pass either way.)
	huge := strings.Repeat("…", 60_000)
	envelope := `{"type":"result","subtype":"error_max_turns","is_error":true,"result":"` + huge + `"}`
	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, envelope, 1))

	_, _, _, err := gen.Generate(context.Background(), "sys", "hi", "")
	if err == nil {
		t.Fatal("Generate returned nil error for an is_error envelope")
	}
	if !utf8.ValidString(err.Error()) {
		t.Errorf("error = %q, want the truncation to land on a rune boundary", err)
	}
}

// TestClaudeGeneratorUnparseableStdoutIsDescribedNotEchoed keeps the
// DescribeOutput doctrine on the failure path: stdout the parser cannot
// understand is model-derived text and must reach logs/UI as a fingerprint.
func TestClaudeGeneratorUnparseableStdoutIsDescribedNotEchoed(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	const secret = "acme-merger-with-globex-is-confidential"
	gen := NewClaudeGenerator("test-model", "test-model", fakeClaude(t, secret, 1))

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

// There is no size threshold any more: the 32 KiB message that used to be
// the largest one inline travels on stdin like any other (board #566).
func TestGenerateArgsThresholdBoundary(t *testing.T) {
	exact := strings.Repeat("x", 32*1024)
	args, stdin := generateArgs("m", "", exact)
	if stdin != exact {
		t.Errorf("stdin = %d bytes, want the whole %d-byte message", len(stdin), len(exact))
	}
	if slices.Contains(args, exact) {
		t.Error("args must never carry the message")
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
		{"light source uses light", WithSource(context.Background(), "digest.period"), "model:light-model"},
		{"strong source uses strong", WithSource(context.Background(), "digest.channel"), "model:strong-model"},
		// The learn-call reclassification (decision 9, fix wave 4, task 6): a
		// bare TierForSource assertion only restates the table, so this proves
		// the tag actually reaches Generate and selects the light model, end
		// to end.
		{"catchup learn source uses light", WithSource(context.Background(), "catchup.learn"), "model:light-model"},
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

func TestGenerateArgsSystemPromptFile(t *testing.T) {
	args, _ := generateArgs("m", "/tmp/p.txt", "hello")
	if !containsPair(args, "--system-prompt-file", "/tmp/p.txt") {
		t.Errorf("args = %v, want --system-prompt-file /tmp/p.txt", args)
	}
	for _, a := range args {
		if a == "--system-prompt" || a == "sys" {
			t.Errorf("args = %v: the prompt must not also travel inline", args)
		}
	}
}

// TestClaudeGeneratorLargeSystemPromptViaFile: a large system prompt
// (briefing, target extract) reaches the CLI through a --system-prompt-file,
// never argv, and the file is removed after the call.
func TestClaudeGeneratorLargeSystemPromptViaFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	const marker = "SYSPROMPT-MARKER-claude-5b1e"
	script := filepath.Join(t.TempDir(), "fake-claude")
	scriptBody := `#!/bin/sh
case "$*" in *` + marker + `*) echo '{"type":"result","result":"on-argv","is_error":false}'; exit 0 ;; esac
file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--system-prompt-file" ]; then file="$2"; fi
  shift
done
if [ -n "$file" ] && grep -q ` + marker + ` "$file"; then
  echo '{"type":"result","result":"'"$file"'","is_error":false}'
else
  echo '{"type":"result","result":"marker-missing","is_error":false}'
fi
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake claude binary: %v", err)
	}

	gen := NewClaudeGenerator("test-model-light", "test-model", script)
	sys := strings.Repeat("x", 64*1024) + marker

	got, _, _, err := gen.Generate(context.Background(), sys, "hello", "")
	if err != nil {
		t.Fatalf("Generate error: %v", err)
	}
	if got == "on-argv" || got == "marker-missing" {
		t.Fatalf("result = %q — the system prompt did not reach the CLI through the file", got)
	}
	if _, statErr := os.Stat(got); !os.IsNotExist(statErr) {
		t.Errorf("system prompt file %q must be removed after Generate, stat err = %v", got, statErr)
	}
}

// TestClaudeGeneratorSmallPromptsNeverOnArgv (board #566): a small system
// prompt and a small user message — the common daemon case — reach the CLI
// through the 0600 file and stdin, and neither ever sits on the child's
// argv, where every local process could read it through `ps`.
func TestClaudeGeneratorSmallPromptsNeverOnArgv(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	const sysMarker, userMarker = "SYS-MARKER-566", "USER-MARKER-566"
	script := filepath.Join(t.TempDir(), "fake-claude")
	scriptBody := `#!/bin/sh
case "$*" in *MARKER-566*) echo '{"type":"result","result":"on-argv","is_error":false}'; exit 0 ;; esac
input=$(cat)
file=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--system-prompt-file" ]; then file="$2"; fi
  shift
done
case "$input" in *` + userMarker + `*) ;; *) echo '{"type":"result","result":"user-missing","is_error":false}'; exit 0 ;; esac
if [ -n "$file" ] && grep -q ` + sysMarker + ` "$file"; then
  echo '{"type":"result","result":"ok","is_error":false}'
else
  echo '{"type":"result","result":"sys-missing","is_error":false}'
fi
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake claude binary: %v", err)
	}

	gen := NewClaudeGenerator("test-model-light", "test-model", script)
	got, _, _, err := gen.Generate(context.Background(), "sys "+sysMarker, "hello "+userMarker, "")
	if err != nil {
		t.Fatalf("Generate error: %v", err)
	}
	if got != "ok" {
		t.Errorf("result = %q, want ok: the prompts must travel by file and stdin, never argv", got)
	}
}

// A message beginning with '-' never follows -p on argv, where claude would
// parse it as a flag (-c is --continue): it travels on stdin.
func TestGenerateArgs_DashLeadingMessageViaStdin(t *testing.T) {
	msg := "-c resume the last session"
	args, stdin := generateArgs("m", "", msg)
	if stdin != msg {
		t.Errorf("stdin = %q, want the message", stdin)
	}
	for _, a := range args {
		if a == msg {
			t.Fatalf("args = %v carry the dash-leading message", args)
		}
	}
}

// Generate's working directory, ~/.config/watchtower, holds the config and
// tokens: created private. So is the workspace a digest lock creates.
func TestGenerateAndDigestLock_CreatePrivateDirectories(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	script := filepath.Join(t.TempDir(), "fake-claude")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho '{\"type\":\"result\",\"result\":\"ok\",\"is_error\":false}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := NewClaudeGenerator("light", "strong", script).Generate(context.Background(), "sys", "hi", ""); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	cfg := &config.Config{ActiveWorkspace: "test"}
	_, unlock, err := (&Pipeline{cfg: cfg}).acquireDigestLock()
	if err != nil {
		t.Fatalf("acquireDigestLock: %v", err)
	}
	defer unlock()
	for _, dir := range []string{filepath.Join(home, ".config", "watchtower"), cfg.WorkspaceDir()} {
		info, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o700 {
			t.Errorf("%s: mode %o, want 700", dir, perm)
		}
	}
}

// An existing ~/.config/watchtower an older install left 0755 is narrowed
// to 0700 when Generate runs from it.
func TestGenerate_NarrowsAnExistingConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, ".config", "watchtower")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(t.TempDir(), "fake-claude")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho '{\"type\":\"result\",\"result\":\"ok\",\"is_error\":false}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := NewClaudeGenerator("light", "strong", script).Generate(context.Background(), "sys", "hi", ""); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	info, err := os.Stat(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Errorf("%s: mode %o, want 700", configDir, perm)
	}
}
