package claude

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"testing/synctest"
	"time"
)

const usageRequestLine = `{"type":"control_request","request_id":"wt-usage","request":{"subtype":"get_usage","skip_behaviors":true}}` + "\n"

func usageCode(t *testing.T, err error) string {
	t.Helper()
	var ue *UsageError
	if !errors.As(err, &ue) {
		t.Fatalf("error %v (%T) is not *UsageError", err, err)
	}
	return ue.Code
}

// usageSuccess wraps a get_usage payload in the wt-usage success answer.
func usageSuccess(payload string) string {
	return `{"type":"control_response","response":{"subtype":"success","request_id":"wt-usage","response":` + payload + `}}`
}

const (
	usageOKPayload          = `{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12.5,"resets_at":null},"seven_day":{"utilization":40,"resets_at":null}}}`
	usageUnavailablePayload = `{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}`
)

// fakeUsageChild is an in-process claude: script runs in its own goroutine
// over two pipes; kill closes the pipes and makes wait return.
type fakeUsageChild struct {
	stdinR, stdoutR *io.PipeReader
	stdinW, stdoutW *io.PipeWriter
	exit            chan int
	killedCh        chan struct{}
	// holdStdout models a descendant outside the group that keeps stdout
	// open: kill does not end the stdout stream.
	holdStdout bool
	killOnce   sync.Once

	mu         sync.Mutex
	killed     bool
	killedAt   time.Time
	answeredAt time.Time
	stdinLines []string
}

func newFakeUsageChild() *fakeUsageChild {
	f := &fakeUsageChild{exit: make(chan int, 1), killedCh: make(chan struct{})}
	f.stdinR, f.stdinW = io.Pipe()
	f.stdoutR, f.stdoutW = io.Pipe()
	return f
}

func (f *fakeUsageChild) child() *usageChild {
	return &usageChild{
		stdin:  f.stdinW,
		stdout: f.stdoutR,
		wait: func() (int, error) {
			select {
			case code := <-f.exit:
				return code, nil
			case <-f.killedCh:
				return -1, errors.New("killed")
			}
		},
		kill: func() {
			f.killOnce.Do(func() {
				f.mu.Lock()
				f.killed, f.killedAt = true, time.Now()
				f.mu.Unlock()
				_ = f.stdinR.Close()
				if !f.holdStdout {
					_ = f.stdoutW.Close()
					_ = f.stdoutR.Close()
				}
				close(f.killedCh)
			})
		},
	}
}

func (f *fakeUsageChild) wasKilled() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.killed
}

// say writes one stdout line; false once the reader is gone.
func (f *fakeUsageChild) say(line string) bool {
	_, err := io.WriteString(f.stdoutW, line+"\n")
	return err == nil
}

// answer records when the wt-usage answer went out.
func (f *fakeUsageChild) answer(line string) {
	if f.say(line) {
		f.mu.Lock()
		f.answeredAt = time.Now()
		f.mu.Unlock()
	}
}

// exitWith closes stdout and exits with code.
func (f *fakeUsageChild) exitWith(code int) {
	_ = f.stdoutW.Close()
	f.exit <- code
}

// readAllStdin records every stdin line until stdin is closed.
func (f *fakeUsageChild) readAllStdin(r *bufio.Reader) {
	for {
		line, err := r.ReadString('\n')
		if line != "" {
			f.mu.Lock()
			f.stdinLines = append(f.stdinLines, line)
			f.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// answering is the common fake: read the request, print the lines, then
// exit 0 once stdin is closed.
func answering(lines ...string) func(*fakeUsageChild) {
	return func(f *fakeUsageChild) {
		r := bufio.NewReader(f.stdinR)
		first, err := r.ReadString('\n')
		if err != nil {
			return
		}
		f.mu.Lock()
		f.stdinLines = append(f.stdinLines, first)
		f.mu.Unlock()
		for i, l := range lines {
			if i == len(lines)-1 {
				f.answer(l)
			} else if !f.say(l) {
				return
			}
		}
		f.readAllStdin(r)
		f.exitWith(0)
	}
}

// runFakeUsage runs readUsage against script inside the current synctest
// bubble.
func runFakeUsage(ctx context.Context, env []string, script func(*fakeUsageChild)) (UsageSnapshot, *fakeUsageChild, error) {
	f := newFakeUsageChild()
	launch := func() (*usageChild, error) {
		go script(f)
		return f.child(), nil
	}
	snap, err := readUsage(ctx, launch, env)
	return snap, f, err
}

func TestReadUsage_CLIMissing(t *testing.T) {
	_, err := ReadUsage(context.Background(), filepath.Join(t.TempDir(), "nope"), []string{"PATH=/nonexistent"})
	if code := usageCode(t, err); code != "cli_missing" {
		t.Fatalf("code = %q, want cli_missing", code)
	}
}

func TestReadUsage_UnsupportedRequest(t *testing.T) {
	for name, line := range map[string]string{
		"error_code": `{"type":"control_response","response":{"subtype":"error","request_id":"wt-usage","error":"nope","error_code":"unsupported_request"}}`,
		"error text": `{"type":"control_response","response":{"subtype":"error","request_id":"wt-usage","error":"Unsupported control request subtype: get_usage"}}`,
	} {
		synctest.Test(t, func(t *testing.T) {
			_, f, err := runFakeUsage(t.Context(), nil, answering(line))
			if code := usageCode(t, err); code != "unsupported_cli" {
				t.Errorf("%s: code = %q, want unsupported_cli", name, code)
			}
			if !f.wasKilled() {
				t.Errorf("%s: group not killed", name)
			}
		})
	}
}

func TestReadUsage_ExitWithoutAnswerIsNetwork(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		_, _, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) { f.exitWith(0) })
		if code := usageCode(t, err); code != "network" {
			t.Errorf("exit 0, empty stdout: code = %q, want network", code)
		}
	})
	synctest.Test(t, func(t *testing.T) {
		_, _, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) {
			f.say(`{"type":"system","subtype":"hook_started"}`)
			f.exitWith(1)
		})
		if code := usageCode(t, err); code != "network" {
			t.Errorf("exit 1 after output: code = %q, want network", code)
		}
	})
	synctest.Test(t, func(t *testing.T) {
		_, _, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) { f.exitWith(2) })
		if code := usageCode(t, err); code != "unsupported_cli" {
			t.Errorf("exit 2, empty stdout: code = %q, want unsupported_cli", code)
		}
	})
}

func TestReadUsage_RateLimitsUnavailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		_, _, err := runFakeUsage(t.Context(), []string{"HOME=/h", "PATH=/p"}, answering(usageSuccess(usageUnavailablePayload)))
		if code := usageCode(t, err); code != "no_credentials" {
			t.Fatalf("code = %q, want no_credentials", code)
		}
	})
}

func TestReadUsage_APIKeyEnvIsUnsupportedAuth(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		snap, _, err := runFakeUsage(t.Context(), []string{"ANTHROPIC_API_KEY=SECRET-MARKER-7"}, answering(usageSuccess(usageUnavailablePayload)))
		if code := usageCode(t, err); code != "unsupported_auth" {
			t.Fatalf("code = %q, want unsupported_auth", code)
		}
		for what, s := range map[string]string{"error": err.Error(), "snapshot": fmt.Sprintf("%+v", snap)} {
			if strings.Contains(s, "SECRET-MARKER-7") {
				t.Errorf("%s carries the env value: %s", what, s)
			}
		}
	})
}

func TestReadUsage_APIKeyEnvWithLimitsAvailableReadsNumbers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		snap, _, err := runFakeUsage(t.Context(), []string{"ANTHROPIC_API_KEY=SECRET-MARKER-7"}, answering(usageSuccess(usageOKPayload)))
		if err != nil {
			t.Fatalf("err = %v", err)
		}
		if len(snap.Windows) != 2 || snap.Plan != "max" {
			t.Fatalf("snapshot = %+v", snap)
		}
	})
}

func TestReadUsage_CloudEnvIsCloudReason(t *testing.T) {
	for env, want := range map[string]string{
		"CLAUDE_CODE_USE_BEDROCK=1": "cloud_bedrock",
		"CLAUDE_CODE_USE_VERTEX=1":  "cloud_vertex",
		"CLAUDE_CODE_USE_FOUNDRY=1": "cloud_foundry",
	} {
		synctest.Test(t, func(t *testing.T) {
			_, _, err := runFakeUsage(t.Context(), []string{env}, answering(usageSuccess(usageUnavailablePayload)))
			if code := usageCode(t, err); code != want {
				t.Errorf("%s: code = %q, want %q", env, code, want)
			}
		})
	}
}

func TestReadUsage_RateLimitsNull(t *testing.T) {
	for _, tc := range []struct{ name, line, want string }{
		{"limits null", usageSuccess(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":null}`), "network"},
		{"other error", `{"type":"control_response","response":{"subtype":"error","request_id":"wt-usage","error":"boom"}}`, "network"},
		{"no windows", usageSuccess(`{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"seven_day":null}}`), "parse"},
		{"undecodable", usageSuccess(`{"rate_limits_available":"yes"}`), "parse"},
		{"odd subtype", `{"type":"control_response","response":{"subtype":"pending","request_id":"wt-usage"}}`, "parse"},
		{"wrong-typed field", `{"type":"control_response","response":{"subtype":"success","request_id":"wt-usage","error_code":5}}`, "parse"},
	} {
		synctest.Test(t, func(t *testing.T) {
			_, _, err := runFakeUsage(t.Context(), nil, answering(tc.line))
			if code := usageCode(t, err); code != tc.want {
				t.Errorf("%s: code = %q, want %q", tc.name, code, tc.want)
			}
		})
	}
}

// Review focus 2: hook and system events, a control_request from the CLI and
// another request's control_response are skipped and never answered.
func TestReadUsage_SkipsOtherLines(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		snap, f, err := runFakeUsage(t.Context(), nil, answering(
			"not json at all",
			`{"type":"system","subtype":"hook_response","hook_name":"SessionStart"}`,
			`{"type":"control_request","request_id":"cli-1","request":{"subtype":"can_use_tool"}}`,
			`{"type":"control_response","response":{"subtype":"error","request_id":"other","error":"x"}}`,
			usageSuccess(usageOKPayload),
		))
		if err != nil {
			t.Fatalf("err = %v", err)
		}
		if len(snap.Windows) != 2 || snap.Windows[0].Key != "session" {
			t.Fatalf("snapshot = %+v", snap)
		}
		if len(f.stdinLines) != 1 || f.stdinLines[0] != usageRequestLine {
			t.Fatalf("stdin = %q, want exactly the request", f.stdinLines)
		}
	})
}

func TestReadUsage_OutputCapped(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		_, f, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) {
			f.say(strings.Repeat("x", usageLineCap+1))
		})
		if code := usageCode(t, err); code != "parse" {
			t.Errorf("long line: code = %q, want parse", code)
		}
		if !f.wasKilled() {
			t.Error("long line: not killed")
		}
	})
	synctest.Test(t, func(t *testing.T) {
		_, f, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) {
			line := strings.Repeat("y", 1000)
			for f.say(line) {
			}
		})
		if code := usageCode(t, err); code != "parse" {
			t.Errorf("total cap: code = %q, want parse", code)
		}
		if !f.wasKilled() {
			t.Error("total cap: not killed")
		}
	})
}

func TestReadUsage_TimeoutReapsGroup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		_, f, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) {
			// Reads the request, never answers; stdin stays open.
			_, _ = io.Copy(io.Discard, f.stdinR)
		})
		if code := usageCode(t, err); code != "timeout" {
			t.Fatalf("code = %q, want timeout", code)
		}
		if d := time.Since(start); d != usageBudget {
			t.Errorf("returned after %v, want %v", d, usageBudget)
		}
		if !f.wasKilled() {
			t.Error("not killed")
		}
	})
}

func TestReadUsage_CancelReaps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		type result struct {
			err error
			f   *fakeUsageChild
		}
		done := make(chan result, 1)
		go func() {
			_, f, err := runFakeUsage(ctx, nil, func(f *fakeUsageChild) { _, _ = io.Copy(io.Discard, f.stdinR) })
			done <- result{err, f}
		}()
		synctest.Wait()
		cancel()
		r := <-done
		if code := usageCode(t, r.err); code != "cancelled" {
			t.Fatalf("code = %q, want cancelled", code)
		}
		if !r.f.wasKilled() {
			t.Error("not killed")
		}
	})
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		started := false
		_, err := readUsage(ctx, func() (*usageChild, error) { started = true; return nil, errors.New("unreachable") }, nil)
		if code := usageCode(t, err); code != "cancelled" || started {
			t.Fatalf("code = %q started = %v, want cancelled without a start", code, started)
		}
	})
}

func TestReadUsage_ExitGraceThenKill(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		snap, f, err := runFakeUsage(t.Context(), nil, func(f *fakeUsageChild) {
			r := bufio.NewReader(f.stdinR)
			if _, err := r.ReadString('\n'); err != nil {
				return
			}
			f.answer(usageSuccess(usageOKPayload))
			<-f.killedCh // ignores the closed stdin
		})
		if err != nil || len(snap.Windows) != 2 {
			t.Fatalf("snap = %+v err = %v", snap, err)
		}
		if !f.wasKilled() {
			t.Fatal("not killed")
		}
		if d := f.killedAt.Sub(f.answeredAt); d != usageExitGrace {
			t.Errorf("killed %v after the answer, want %v", d, usageExitGrace)
		}
	})
}

// Review fix: a child that exits without answering while an escaped
// descendant keeps stdout open ends at the budget, not later.
func TestReadUsage_EscapedDescendantHoldsStdout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newFakeUsageChild()
		f.holdStdout = true
		start := time.Now()
		_, err := readUsage(t.Context(), func() (*usageChild, error) {
			go func() {
				_, _ = bufio.NewReader(f.stdinR).ReadString('\n')
				f.exit <- 0 // exits; stdout stays open
			}()
			return f.child(), nil
		}, nil)
		if code := usageCode(t, err); code != "timeout" {
			t.Fatalf("code = %q, want timeout", code)
		}
		if d := time.Since(start); d != usageBudget {
			t.Errorf("returned after %v, want %v", d, usageBudget)
		}
		_ = f.stdoutW.Close() // the descendant finally goes away
	})
}

// --- script tests: a real /bin/sh child -------------------------------------

// writeUsageScript writes an executable /bin/sh fake claude whose first act
// is recording its PID (= its process group, the reader starts it with
// Setpgid); cleanup kills that group.
func writeUsageScript(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "claude")
	text := "#!/bin/sh\necho $$ > '" + pidFile + "'\n" + body + "\n"
	if err := os.WriteFile(script, []byte(text), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
		if err != nil || pid <= 0 {
			return
		}
		// ESRCH: the group is gone. EPERM: darwin's answer for a group
		// whose remaining members are exiting zombies.
		if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) && !errors.Is(err, syscall.EPERM) {
			t.Errorf("kill group %d: %v", pid, err)
		}
	})
	return script
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func TestReadUsage_FlagsRejected(t *testing.T) {
	bin := writeUsageScript(t, "exit 1")
	_, err := ReadUsage(t.Context(), bin, []string{"PATH=/usr/bin:/bin"})
	if code := usageCode(t, err); code != "unsupported_cli" {
		t.Fatalf("code = %q, want unsupported_cli", code)
	}
}

// Review fix: a descendant that escapes the process group (setsid) and keeps
// stdout and stderr open must not hold ReadUsage after the answer: stderr is
// not a pipe and Wait is bounded.
func TestReadUsage_EscapedDescendantDoesNotHang(t *testing.T) {
	perl, err := exec.LookPath("perl")
	if err != nil {
		t.Skip("perl not installed")
	}
	holderPid := filepath.Join(t.TempDir(), "holder")
	bin := writeUsageScript(t, strings.Join([]string{
		`IFS= read -r line`,
		shQuote(perl) + ` -e 'use POSIX; POSIX::setsid(); sleep 300' &`,
		`echo $! > ` + shQuote(holderPid),
		`printf '%s\n' ` + shQuote(usageSuccess(usageOKPayload)),
		`/bin/cat >/dev/null`,
	}, "\n"))
	t.Cleanup(func() {
		if b, err := os.ReadFile(holderPid); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
	snap, err := ReadUsage(t.Context(), bin, []string{"PATH=/usr/bin:/bin"})
	if err != nil || len(snap.Windows) != 2 {
		t.Fatalf("snap = %+v err = %v", snap, err)
	}
}

// Review fix: a relative bin resolves against the caller's cwd, not the
// child's neutral folder.
func TestReadUsage_RelativeBin(t *testing.T) {
	bin := writeUsageScript(t, "IFS= read -r line\nprintf '%s\\n' "+shQuote(usageSuccess(usageOKPayload))+"\n/bin/cat >/dev/null")
	t.Chdir(filepath.Dir(bin))
	snap, err := ReadUsage(t.Context(), "./"+filepath.Base(bin), []string{"PATH=/usr/bin:/bin"})
	if err != nil || len(snap.Windows) != 2 {
		t.Fatalf("snap = %+v err = %v", snap, err)
	}
}

// Review focus 5: a chatty stderr must not block the answer.
func TestReadUsage_LargeStderrDoesNotBlock(t *testing.T) {
	bin := writeUsageScript(t, "IFS= read -r line\n/usr/bin/head -c 2000000 /dev/zero >&2\nprintf '%s\\n' "+shQuote(usageSuccess(usageOKPayload))+"\n/bin/cat >/dev/null")
	snap, err := ReadUsage(t.Context(), bin, []string{"PATH=/usr/bin:/bin"})
	if err != nil || len(snap.Windows) != 2 {
		t.Fatalf("snap = %+v err = %v", snap, err)
	}
}

// PLANUSAGE-01: the reader starts claude with exactly the pinned argv, in the
// neutral temp folder, writes nothing but the one request, and touches no
// credential tool or file.
func TestPlanUsage01_ReaderArgvAndHome(t *testing.T) {
	out := t.TempDir()
	home := t.TempDir()
	decoyBin := t.TempDir()
	marker := filepath.Join(out, "decoy-ran")
	for _, name := range []string{"security", "curl"} {
		decoy := "#!/bin/sh\n/usr/bin/touch " + shQuote(marker) + "\n"
		if err := os.WriteFile(filepath.Join(decoyBin, name), []byte(decoy), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	credDir := filepath.Join(home, ".claude")
	if err := os.MkdirAll(credDir, 0o700); err != nil {
		t.Fatal(err)
	}
	credFile := filepath.Join(credDir, ".credentials.json")
	decoyCreds := []byte(`{"claudeAiOauth":{"accessToken":"DECOY-TOKEN"}}`)
	if err := os.WriteFile(credFile, decoyCreds, 0o600); err != nil {
		t.Fatal(err)
	}

	args, cwd, first, rest := filepath.Join(out, "args"), filepath.Join(out, "cwd"), filepath.Join(out, "stdin1"), filepath.Join(out, "rest")
	body := strings.Join([]string{
		`for a in "$@"; do printf '%s\n' "$a" >> ` + shQuote(args) + `; done`,
		`pwd > ` + shQuote(cwd),
		`if IFS= read -r line; then printf '%s\n' "$line" > ` + shQuote(first) + `; else printf 'NOEOL' > ` + shQuote(first) + `; fi`,
		`printf '%s\n' ` + shQuote(usageSuccess(usageOKPayload)),
		`/bin/cat > ` + shQuote(rest),
	}, "\n")
	bin := writeUsageScript(t, body)

	snap, err := ReadUsage(t.Context(), bin, []string{"HOME=" + home, "PATH=" + decoyBin})
	if err != nil || len(snap.Windows) != 2 {
		t.Fatalf("snap = %+v err = %v", snap, err)
	}

	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s: %v", filepath.Base(p), err)
		}
		return string(b)
	}
	// The plan's Global Constraints argv, verbatim; not usageArgs, so a flag
	// dropped from the reader fails here.
	pinned := "-p --input-format stream-json --output-format stream-json --verbose --setting-sources project --strict-mcp-config --no-session-persistence"
	if got, want := read(args), strings.Join(strings.Fields(pinned), "\n")+"\n"; got != want {
		t.Errorf("argv = %q, want %q", got, want)
	}
	wantDir, err := filepath.EvalSymlinks(os.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	gotDir, err := filepath.EvalSymlinks(strings.TrimSpace(read(cwd)))
	if err != nil {
		t.Fatal(err)
	}
	if gotDir != wantDir {
		t.Errorf("cwd = %q, want %q", gotDir, wantDir)
	}
	if got := read(first); got != usageRequestLine {
		t.Errorf("stdin line = %q, want %q", got, usageRequestLine)
	}
	if got := read(rest); got != "" {
		t.Errorf("stdin after the request = %q, want nothing", got)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a decoy credential tool ran (stat err %v)", err)
	}
	if got, err := os.ReadFile(credFile); err != nil || !bytes.Equal(got, decoyCreds) {
		t.Errorf("decoy credentials changed: %q %v", got, err)
	}
}
