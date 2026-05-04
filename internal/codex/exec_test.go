package codex

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeCodexScript writes a temporary executable shell script that prints the
// given stdout content (and optional stderr) and exits with the given code.
// It returns the path to the script. The script is suitable as a stand-in for
// the codex CLI binary in tests.
func fakeCodexScript(t *testing.T, stdout, stderrMsg string, exitCode int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI test skipped on windows")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "codex")

	// Heredoc-encode stdout to preserve newlines and quoting.
	body := fmt.Sprintf(`#!/bin/sh
cat <<'__STDOUT_EOF__'
%s
__STDOUT_EOF__
`, stdout)
	if stderrMsg != "" {
		body += fmt.Sprintf("printf '%%s' %q 1>&2\n", stderrMsg)
	}
	body += fmt.Sprintf("exit %d\n", exitCode)

	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestQuerySync_ParsesJSONLOutput(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"Hello, world!"}}`,
		`{"type":"usage","usage":{"input_tokens":42,"output_tokens":17}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	c := NewClient("gpt-5.4", "", bin)
	out, usage, err := c.QuerySync(context.Background(), "system", "user", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "Hello, world!" {
		t.Errorf("output = %q", out)
	}
	if usage == nil || usage.InputTokens != 42 || usage.OutputTokens != 17 {
		t.Errorf("usage = %+v", usage)
	}
}

func TestQuerySync_PropagatesNonZeroExit(t *testing.T) {
	bin := fakeCodexScript(t, "", "boom", 7)
	c := NewClient("gpt-5.4", "", bin)
	_, _, err := c.QuerySync(context.Background(), "", "x", "")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error should include stderr, got: %v", err)
	}
}

// classifyError is exhaustively tested in generator_test.go; covered here
// transitively via exec failure paths.

func TestQuerySync_ContextCancel(t *testing.T) {
	// The script sleeps; a cancelled context should kill it promptly.
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	body := "#!/bin/sh\nsleep 5\n"
	if err := os.WriteFile(bin, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	c := NewClient("gpt-5.4", "", bin)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	_, _, err := c.QuerySync(ctx, "", "x", "")
	if err == nil {
		t.Fatal("expected error from cancelled context")
	}
}

func TestQuery_StreamsAgentMessages(t *testing.T) {
	// Multiple chunks; Query should emit one text event per agent_message.
	stdout := strings.Join([]string{
		`{"type":"item.started","item":{"type":"agent_message","text":"Hello "}}`,
		`{"type":"item.updated","item":{"type":"agent_message","text":"world"}}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"!"}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	c := NewClient("gpt-5.4", "", bin)

	textCh, errCh, sidCh := c.Query(context.Background(), "", "user", "")

	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk)
	}
	// Drain the rest.
	if err := <-errCh; err != nil {
		t.Fatalf("Query error: %v", err)
	}
	sid := <-sidCh
	if sid != "" {
		t.Errorf("expected empty session ID for codex (--ephemeral), got %q", sid)
	}
	if !strings.Contains(got.String(), "Hello") || !strings.Contains(got.String(), "world") {
		t.Errorf("missing streamed text, got %q", got.String())
	}
}

func TestQuery_ErrorEvent(t *testing.T) {
	stdout := `{"type":"error","error":{"message":"rate limited"}}`
	bin := fakeCodexScript(t, stdout, "", 0)

	c := NewClient("gpt-5.4", "", bin)
	textCh, errCh, _ := c.Query(context.Background(), "", "user", "")

	// Drain text channel.
	for range textCh {
	}
	err := <-errCh
	if err == nil {
		t.Fatal("expected codex error to surface")
	}
	if !strings.Contains(err.Error(), "rate limited") {
		t.Errorf("error should include codex message, got: %v", err)
	}
}

func TestGenerate_ParsesJSONL(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"Generated text"}}`,
		`{"type":"usage","usage":{"input_tokens":10,"output_tokens":5}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	g := NewCodexGenerator("gpt-5.4", bin)
	out, usage, sid, err := g.Generate(context.Background(), "sys", "msg", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "Generated text" {
		t.Errorf("output = %q", out)
	}
	if sid != "" {
		t.Errorf("session ID must be empty for codex, got %q", sid)
	}
	if usage == nil || usage.Model != "gpt-5.4" {
		t.Errorf("usage = %+v", usage)
	}
	if usage.InputTokens != 10 || usage.OutputTokens != 5 {
		t.Errorf("usage tokens = %d/%d", usage.InputTokens, usage.OutputTokens)
	}
}

func TestGenerate_EmptyResultIsError(t *testing.T) {
	// item.completed without text → empty content → error.
	stdout := `{"type":"item.completed","item":{"type":"agent_message","text":""}}`
	bin := fakeCodexScript(t, stdout, "", 0)

	g := NewCodexGenerator("gpt-5.4", bin)
	_, _, _, err := g.Generate(context.Background(), "", "msg", "")
	if err == nil {
		t.Fatal("expected error for empty result")
	}
}

func TestLoginShellWhich_RejectsBadNames(t *testing.T) {
	cases := []string{
		"foo;bar",
		"name with space",
		"`rm -rf /`",
		"$(whoami)",
		"name|pipe",
		"",
	}
	for _, name := range cases {
		if got := loginShellWhich(name); got != "" {
			t.Errorf("loginShellWhich(%q) = %q, want empty", name, got)
		}
	}
}

func TestLoginShellWhich_AcceptsValidNames(t *testing.T) {
	// Should not panic; result depends on host environment.
	_ = loginShellWhich("sh")
	_ = loginShellWhich("test-binary_1")
}

// resetCacheParallel ensures resolve cache reset is safe to call from concurrent
// tests. Currently a smoke test for race detector.
func TestResetCache_RaceFree(t *testing.T) {
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resetCache()
		}()
	}
	wg.Wait()
}
