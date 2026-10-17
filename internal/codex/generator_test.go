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
	gen := NewCodexGenerator("gpt-5.4-mini", "gpt-5.4", "/usr/local/bin/codex")
	if gen.modelLight != "gpt-5.4-mini" {
		t.Errorf("modelLight = %q, want %q", gen.modelLight, "gpt-5.4-mini")
	}
	if gen.modelStrong != "gpt-5.4" {
		t.Errorf("modelStrong = %q, want %q", gen.modelStrong, "gpt-5.4")
	}
	if gen.codexPath != "/usr/local/bin/codex" {
		t.Errorf("codexPath = %q, want %q", gen.codexPath, "/usr/local/bin/codex")
	}
}

// A small message and system prompt — the common daemon case — travel on
// stdin too, never on argv, where every local process could read them
// through `ps` (board #566).
func TestCodexArgsSmallMessageViaStdin(t *testing.T) {
	args, stdin := buildArgs("gpt-5.4", "sys", "hello")
	if want := codexStdinContent("sys", "hello"); stdin != want {
		t.Errorf("stdin = %q, want %q", stdin, want)
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Errorf("args = %v, want \"-\" as the last positional arg", args)
	}
	for _, a := range args {
		if a == "hello" || strings.HasPrefix(a, "developer_instructions=") {
			t.Errorf("args = %v carry prompt text", args)
		}
	}
}

func TestCodexArgsLargeMessageViaStdin(t *testing.T) {
	big := strings.Repeat("x", 64*1024)
	args, stdin := buildArgs("gpt-5.4", "", big)
	if stdin != codexStdinUserHeader+big {
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

	gen := NewCodexGenerator("test-model-light", "test-model", script)
	big := strings.Repeat("x", 64*1024) + marker // well past a single argv value's limit

	got, _, _, err := gen.Generate(context.Background(), "sys", big, "")
	if err != nil {
		t.Fatalf("Generate error: %v", err)
	}
	if got != "got:"+marker {
		t.Errorf("result = %q, want %q — the user message did not reach the subprocess via stdin", got, "got:"+marker)
	}
}

// There is no size threshold any more: the 32 KiB message that used to be
// the largest positional travels on stdin like any other (board #566).
func TestCodexArgsThresholdBoundary(t *testing.T) {
	exact := strings.Repeat("x", 32*1024)
	args, stdin := buildArgs("gpt-5.4", "", exact)
	if stdin != codexStdinUserHeader+exact {
		t.Errorf("stdin = %d bytes, want the whole 32 KiB message", len(stdin))
	}
	if len(args) == 0 || args[len(args)-1] != "-" {
		t.Error("args must end in \"-\", never carry the message")
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

// TestGenerate_TierRoutingHearsDigestSource pins the fix for the context-key
// mismatch: codex used to declare its own sessionSourceKey type, which never
// matched digest.WithSource, so tier routing silently never fired.
func TestGenerate_TierRoutingHearsDigestSource(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "codex")
	// Echo the value following --model back as the agent message text.
	scriptBody := `#!/bin/sh
model=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--model" ]; then model="$a"; fi
  prev="$a"
done
echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"model:$model\"}}"
`
	if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
		t.Fatalf("writing fake codex binary: %v", err)
	}

	gen := NewCodexGenerator("mini-model", "big-model", script)

	tests := []struct {
		name string
		ctx  context.Context
		want string
	}{
		{"untagged uses strong", context.Background(), "model:big-model"},
		{"light source uses light", digest.WithSource(context.Background(), "digest.period"), "model:mini-model"},
		{"strong source uses strong", digest.WithSource(context.Background(), "digest.channel"), "model:big-model"},
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

// TestCodexArgs_LocalToolsDisabled pins the codex twin of the claude side's
// `--tools ""`: every `codex exec` Watchtower starts — batch generator, plain
// client, chat session client — switches off the shell and the other
// local tools, since read-only sandboxing still lets a shell read anywhere on
// disk (TCC prompts, local files pulled into stored output).
func TestCodexArgs_LocalToolsDisabled(t *testing.T) {
	genArgs, _ := buildArgs("gpt-5.4", "sys", "hello")
	plain := NewClient("gpt-5.4", "", "codex")
	clientArgs, _ := plain.buildArgs("sys", "hello", "/tmp/wd")
	session := NewClient("gpt-5.4", "", "codex")
	session.SetMCPArgs([]string{"--chat"})
	sessionArgs, _ := session.buildArgs("sys", "hello", "/tmp/wd")

	for name, args := range map[string][]string{
		"generator":      genArgs,
		"client":         clientArgs,
		"session client": sessionArgs,
	} {
		for _, flag := range []string{
			"features.shell_tool=false",
			"features.unified_exec=false",
			"features.view_image=false",
			"features.computer_use=false",
			"features.browser_use=false",
			"features.browser_use_external=false",
			"features.apps=false",
			"features.plugins=false",
		} {
			found := false
			for i := 0; i < len(args)-1; i++ {
				if args[i] == "-c" && args[i+1] == flag {
					found = true
				}
			}
			if !found {
				t.Errorf("%s args %v: want -c %s", name, args, flag)
			}
		}
	}
}

// TestCodexArgs_LargeSystemPromptMovesTurnToStdin: a system prompt never
// rides -c developer_instructions (ARG_MAX, `ps`), so the generator and the
// plain client move the whole turn to stdin — for a small prompt too (board
// #566).
func TestCodexArgs_LargeSystemPromptMovesTurnToStdin(t *testing.T) {
	big := strings.Repeat("s", 64*1024)
	genArgs, genStdin := buildArgs("gpt-5.4", big, "hello")
	clientArgs, clientStdin := NewClient("gpt-5.4", "", "codex").buildArgs(big, "hello", "")

	for name, got := range map[string]struct {
		args  []string
		stdin string
	}{
		"generator": {genArgs, genStdin},
		"client":    {clientArgs, clientStdin},
	} {
		for _, a := range got.args {
			if strings.Contains(a, big) {
				t.Errorf("%s: argv carries the system prompt", name)
			}
		}
		if got.args[len(got.args)-1] != "-" {
			t.Errorf("%s: last arg = %q, want \"-\"", name, got.args[len(got.args)-1])
		}
		if got.stdin != codexStdinContent(big, "hello") {
			t.Errorf("%s: stdin is not the delimited system+user turn", name)
		}
	}

	small := "small system prompt"
	args, stdin := buildArgs("gpt-5.4", small, "hello")
	if stdin != codexStdinContent(small, "hello") || args[len(args)-1] != "-" {
		t.Errorf("a small system prompt must move the turn to stdin too, got last arg %q, stdin %q", args[len(args)-1], stdin)
	}
	for _, a := range args {
		if strings.Contains(a, small) {
			t.Errorf("argv %v carries the small system prompt", args)
		}
	}
}

// SetIsolatedChild runs codex in its own process group without the dropped
// variables. A fake codex binary records both.
func TestCodexGenerator_IsolatedChild(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "fake-codex")
	body := "#!/bin/sh\nenv > '" + dir + "/env'\nps -o pgid= -p $$ | tr -d ' ' > '" + dir + "/pgid'\necho $$ > '" + dir + "/pid'\n" +
		"cat > /dev/null\necho '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok\"}}'\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WT_DROP_ME", "1")
	gen := NewCodexGenerator("light", "strong", script)
	gen.SetIsolatedChild("WT_DROP_ME")
	reply, _, _, err := gen.Generate(context.Background(), "system", "user", "")
	if err != nil || reply != "ok" {
		t.Fatalf("reply %q, err %v", reply, err)
	}
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(b))
	}
	if strings.Contains(read("env"), "WT_DROP_ME=") {
		t.Fatal("the dropped variable reached codex")
	}
	if read("pid") != read("pgid") {
		t.Fatalf("codex runs in group %s, not its own (%s)", read("pgid"), read("pid"))
	}
}

// A message beginning with '-' never rides argv as the positional prompt,
// where codex would parse it as a flag (-c is a config override): it goes
// through stdin behind "-".
func TestCodexArgs_DashLeadingMessageViaStdin(t *testing.T) {
	msg := `-c sandbox_mode="danger-full-access"`
	args, stdin := buildArgs("gpt-5.4", "", msg)
	if stdin != codexStdinUserHeader+msg {
		t.Errorf("stdin = %q, want the message", stdin)
	}
	if args[len(args)-1] != "-" {
		t.Errorf("last arg = %q, want \"-\"", args[len(args)-1])
	}
	for _, a := range args {
		if a == msg {
			t.Fatalf("args = %v carry the dash-leading message", args)
		}
	}
}
