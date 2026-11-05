package codex

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// useRealVersionProbe restores the real `codex --version` probe for one
// test (TestMain stubs it); the test points it at a fake codex only.
func useRealVersionProbe(t *testing.T) {
	t.Helper()
	prev := probeCodexVersion
	probeCodexVersion = codexVersion
	t.Cleanup(func() { probeCodexVersion = prev })
}

// fakeCodexVersion writes a fake codex that prints version for --version
// and counts its --version runs in the returned file.
func fakeCodexVersion(t *testing.T, version string) (bin, countFile string) {
	t.Helper()
	dir := t.TempDir()
	bin = filepath.Join(dir, "codex")
	countFile = filepath.Join(dir, "count")
	body := "#!/bin/sh\n[ \"$1\" = \"--version\" ] && { echo x >> '" + countFile + "'; echo '" + version + "'; exit 0; }\nexit 1\n"
	if err := os.WriteFile(bin, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, countFile
}

func TestParseCodexVersion(t *testing.T) {
	for in, want := range map[string][3]int{
		"codex-cli 0.145.0\n":  {0, 145, 0},
		"0.145.1":              {0, 145, 1},
		"codex-cli v1.2.3":     {1, 2, 3},
		"codex-cli 0.146.0-a1": {0, 146, 0},
	} {
		got, err := parseCodexVersion(in)
		if err != nil || got != want {
			t.Errorf("parseCodexVersion(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, in := range []string{"", "codex-cli", "codex-cli 0.145", "codex-cli x.y.z"} {
		if _, err := parseCodexVersion(in); err == nil {
			t.Errorf("parseCodexVersion(%q) must fail", in)
		}
	}
}

// The version gate (board #566): model_instructions_file only from
// minInstructionsFileVersion on; an older codex, or one whose version
// cannot be read, keeps the prompt off argv by the stdin layout. A read
// version is probed once per binary; a failed probe is retried later
// (TestInstructionsFileSupported_FailedProbeIsRetried).
func TestInstructionsFileSupported_ByVersion(t *testing.T) {
	useRealVersionProbe(t)
	for version, want := range map[string]bool{
		"codex-cli 0.145.0": true,
		"codex-cli 0.150.2": true,
		"codex-cli 1.0.0":   true,
		"codex-cli 0.144.9": false,
		"codex-cli 0.99.0":  false,
		"garbage":           false,
	} {
		bin, count := fakeCodexVersion(t, version)
		for range 2 {
			if got := instructionsFileSupported(bin); got != want {
				t.Errorf("%s: supported = %v, want %v", version, got, want)
			}
		}
		if b, _ := os.ReadFile(count); strings.Count(string(b), "x") != 1 {
			t.Errorf("%s: --version ran %d times, want once (cached)", version, strings.Count(string(b), "x"))
		}
	}
	if instructionsFileSupported(filepath.Join(t.TempDir(), "missing-codex")) {
		t.Error("a codex that cannot be run must count as too old")
	}
}

// A probe that fails (the binary cannot run, times out, prints garbage) is
// not remembered for the process lifetime: within instructionsProbeRetry the
// stdin layout stays without a new probe, after it the next run probes again
// and a success is then kept for good (#669 follow-up: one slow probe at
// daemon start moved every system prompt to stdin until a restart).
func TestInstructionsFileSupported_FailedProbeIsRetried(t *testing.T) {
	useRealVersionProbe(t)
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	count := filepath.Join(dir, "count")
	// Fails its first --version, prints a good version from then on.
	body := "#!/bin/sh\n[ \"$1\" = \"--version\" ] || exit 1\necho x >> '" + count + "'\n" +
		"[ \"$(wc -l < '" + count + "' | tr -d ' ')\" = 1 ] && exit 1\necho 'codex-cli 0.150.0'\n"
	require.NoError(t, os.WriteFile(bin, []byte(body), 0o755))
	runs := func() int { b, _ := os.ReadFile(count); return strings.Count(string(b), "x") }

	prev := instructionsProbeRetry
	t.Cleanup(func() { instructionsProbeRetry = prev })
	instructionsProbeRetry = time.Hour
	assert.False(t, instructionsFileSupported(bin), "the failed probe falls back to stdin")
	assert.False(t, instructionsFileSupported(bin), "within the retry window")
	assert.Equal(t, 1, runs(), "no new probe inside the retry window")

	instructionsProbeRetry = 0
	assert.True(t, instructionsFileSupported(bin), "the retry after the window succeeds")
	assert.Equal(t, 2, runs())
	assert.True(t, instructionsFileSupported(bin))
	assert.Equal(t, 2, runs(), "a success is cached")
}

// On a codex older than the gate the system prompt travels ahead of the
// user message on stdin — still never on argv — and no file is written.
func TestBuildArgs_OldCodexPutsSystemPromptOnStdin(t *testing.T) {
	useRealVersionProbe(t)
	bin, _ := fakeCodexVersion(t, "codex-cli 0.120.0")
	const sys, user = "SYS-SECRET-old", "USER-SECRET-old"

	for name, build := range map[string]func() ([]string, string, string, error){
		"generator": func() ([]string, string, string, error) { return buildArgs(bin, "m", sys, user) },
		"client": func() ([]string, string, string, error) {
			return NewClient("m", "", bin).buildArgs(sys, user, "")
		},
	} {
		args, stdin, promptFile, err := build()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if promptFile != "" || instructionsFileOf(t, args) != "" {
			t.Errorf("%s: an old codex gets no model_instructions_file (%q, %v)", name, promptFile, args)
		}
		if argvCarries(args, sys) || argvCarries(args, user) {
			t.Errorf("%s: argv %v carries a prompt", name, args)
		}
		if stdin != codexStdinContent(sys, user) {
			t.Errorf("%s: stdin = %q, want the delimited system+user turn", name, stdin)
		}
		if args[len(args)-1] != "-" {
			t.Errorf("%s: last arg = %q, want \"-\"", name, args[len(args)-1])
		}
	}
}

// End to end on an old codex: the fake checks its argv and stdin.
func TestQuerySync_OldCodexPromptsNeverReachArgv(t *testing.T) {
	useRealVersionProbe(t)
	const sysMarker, userMarker = "SYS-MARKER-old", "USER-MARKER-old"
	script := filepath.Join(t.TempDir(), "fake-codex")
	body := `#!/bin/sh
[ "$1" = "--version" ] && { echo "codex-cli 0.120.0"; exit 0; }
reply() { echo '{"type":"item.completed","item":{"type":"agent_message","text":"'"$1"'"}}'; exit 0; }
case "$*" in *MARKER-old*|*model_instructions_file*) reply on-argv ;; esac
input=$(cat)
case "$input" in *` + sysMarker + `*` + userMarker + `*) reply ok ;; esac
reply missing
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	out, _, err := NewClient("m", "", script).QuerySync(context.Background(), "sys "+sysMarker, "hi "+userMarker, "")
	if err != nil {
		t.Fatalf("QuerySync: %v", err)
	}
	if out != "ok" {
		t.Errorf("output = %q, want ok: both prompts on stdin, nothing on argv", out)
	}
}

// The path rides a `-c key="…"` override, so it is quoted as a TOML basic
// string; a path no temp dir produces (control characters, invalid UTF-8)
// is refused rather than escaped.
func TestTOMLBasicString(t *testing.T) {
	for in, want := range map[string]string{
		"/tmp/wt-system-prompt-1.txt": `"/tmp/wt-system-prompt-1.txt"`,
		`/tmp/a "b"\c`:                `"/tmp/a \"b\"\\c"`,
		"/tmp/ünïcode dir/p.txt":      `"/tmp/ünïcode dir/p.txt"`,
	} {
		got, err := tomlBasicString(in)
		if err != nil || got != want {
			t.Errorf("tomlBasicString(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"/tmp/a\nb", "/tmp/a\tb", "/tmp/a\x7fb", "/tmp/\xff"} {
		if _, err := tomlBasicString(in); err == nil {
			t.Errorf("tomlBasicString(%q) must be refused", in)
		}
	}
}

// A TMPDIR with a control character fails the call with a clear error and
// leaves no file behind, instead of handing codex a broken override.
func TestPromptArgs_RefusesAnUnquotablePath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "bad\ndir")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Skipf("cannot create a directory with a newline: %v", err)
	}
	t.Setenv("TMPDIR", dir)
	_, _, path, err := promptArgs("codex", "sys", "hi")
	if err == nil || !strings.Contains(err.Error(), "control character") {
		t.Fatalf("err = %v, want a control-character refusal", err)
	}
	if path != "" {
		t.Errorf("path = %q, want none", path)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("the temp file must be removed, found %d entries", len(entries))
	}
}

// codex refuses a pipe for model_instructions_file (it stats the file:
// "model instructions file is empty: /dev/fd/3", codex-cli 0.145.0), so the
// prompt is a 0600 file. codex re-reads that file for every model request,
// not only at start-up: removed at the first output line, the next request
// of the same run fails ("failed to load workspace requirements",
// codex-cli 0.159.2). So the file lives while the child runs and is never
// left behind. The fake reads the file before any output and again after
// it, as codex does across its requests.
func TestPromptFile_KeptUntilCodexExits(t *testing.T) {
	useRealVersionProbe(t)
	const marker = "SYS-MARKER-once"
	body := `#!/bin/sh
[ "$1" = "--version" ] && { echo "codex-cli 0.145.0"; exit 0; }
echo $$ > "$WT_TEST_PID_FILE"
file=""
for a in "$@"; do case "$a" in model_instructions_file=*) file=${a#model_instructions_file=}; file=${file#\"}; file=${file%\"} ;; esac; done
cat > /dev/null
first=$(cat "$file"); second=$(cat "$file")
reply() { echo '{"type":"item.completed","item":{"type":"agent_message","text":"'"$1"'"}}'; exit 0; }
case "$first$second" in *` + marker + `*` + marker + `*) ;; *) reply unread ;; esac
echo '{"type":"thread.started","thread_id":"t"}'
sleep 0.5
case "$(cat "$file" 2>/dev/null)" in *` + marker + `*) reply present ;; esac
reply gone
`
	cases := []struct {
		name string
		run  func(ctx context.Context, script string) (string, error)
	}{
		{"client", func(ctx context.Context, script string) (string, error) {
			c := NewClient("m", "", script)
			c.SetProcessGroup(true)
			out, _, err := c.QuerySync(ctx, "sys "+marker, "hi", "")
			return out, err
		}},
		{"client stream", func(ctx context.Context, script string) (string, error) {
			c := NewClient("m", "", script)
			c.SetProcessGroup(true)
			chunks, errs, sids := c.Query(ctx, "sys "+marker, "hi", "")
			go func() {
				for range sids {
				}
			}()
			var out strings.Builder
			for chunk := range chunks {
				out.WriteString(chunk.Text)
			}
			return out.String(), <-errs
		}},
		{"generator", func(ctx context.Context, script string) (string, error) {
			g := NewCodexGenerator("m", "m", script)
			g.SetIsolatedChild()
			out, _, _, err := g.Generate(ctx, "sys "+marker, "hi", "")
			return out, err
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tmp := t.TempDir()
			t.Setenv("TMPDIR", tmp)
			pidFile := filepath.Join(t.TempDir(), "pid")
			t.Setenv("WT_TEST_PID_FILE", pidFile)
			script := filepath.Join(t.TempDir(), "fake-codex")
			if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
				t.Fatal(err)
			}
			// The stub leads its own process group and exits by itself in half
			// a second. Whatever path the call took (reply, timeout, failure),
			// kill the group if it is still alive and wait until it is gone.
			t.Cleanup(func() {
				b, _ := os.ReadFile(pidFile)
				pgid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
				if pgid <= 0 || syscall.Kill(-pgid, 0) == syscall.ESRCH {
					return
				}
				_ = syscall.Kill(-pgid, syscall.SIGKILL)
				deadline := time.Now().Add(10 * time.Second)
				for syscall.Kill(-pgid, 0) != syscall.ESRCH {
					if time.Now().After(deadline) {
						t.Errorf("stub process group %d still alive", pgid)
						return
					}
					time.Sleep(20 * time.Millisecond)
				}
			})
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			out, err := tc.run(ctx, script)
			if err != nil || out != "present" {
				t.Errorf("output = %q, %v; want present (the file must outlive codex's first output)", out, err)
			}
			if entries, _ := os.ReadDir(tmp); len(entries) != 0 {
				t.Errorf("%d file(s) left in the temp dir", len(entries))
			}
		})
	}
}
