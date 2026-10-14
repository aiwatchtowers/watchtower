package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The fake app-server is this test binary re-run with fakeModeEnv set:
// TestMain then serves stdin instead of running tests.
const (
	fakeModeEnv  = "WT_FAKE_APPSERVER_MODE"  // ok | ok-child | hang | unknown-method
	fakeLogEnv   = "WT_FAKE_APPSERVER_LOG"   // every request received, one JSON line each
	fakeHooksEnv = "WT_FAKE_APPSERVER_HOOKS" // hooks/list's hooks, a JSON array
	fakePIDsEnv  = "WT_FAKE_APPSERVER_PIDS"  // hang: "<server pid> <child pid>"
)

func TestMain(m *testing.M) {
	if mode := os.Getenv(fakeModeEnv); mode != "" {
		os.Exit(runFakeAppServer(mode))
	}
	os.Exit(m.Run())
}

func runFakeAppServer(mode string) int {
	if mode == "hang" || mode == "ok-child" {
		child := exec.Command("sleep", "30")
		if err := child.Start(); err != nil {
			return 2
		}
		pids := fmt.Sprintf("%d %d", os.Getpid(), child.Process.Pid)
		if err := os.WriteFile(os.Getenv(fakePIDsEnv), []byte(pids), 0o600); err != nil {
			return 2
		}
	}
	logFile, err := os.OpenFile(os.Getenv(fakeLogEnv), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return 2
	}
	defer func() { _ = logFile.Close() }()
	out := json.NewEncoder(os.Stdout)
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		_, _ = logFile.Write(append(sc.Bytes(), '\n'))
		var req struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil || req.ID == nil || mode == "hang" {
			continue
		}
		if mode == "huge" { // one line over the client's 16 MiB buffer
			_, _ = os.Stdout.Write(append([]byte(strings.Repeat("x", 17<<20)), '\n'))
			continue
		}
		// A notification first, as the real server sends them unasked.
		_ = out.Encode(map[string]any{"method": "remoteControl/status/changed", "params": map[string]any{}})
		_ = out.Encode(fakeAnswer(strings.TrimSuffix(mode, "-child"), *req.ID, req.Method))
	}
	return 0
}

func fakeAnswer(mode string, id int, method string) map[string]any {
	switch {
	case method == "initialize":
		return map[string]any{"id": id, "result": map[string]any{"userAgent": "fake/0"}}
	case method == "hooks/list" && mode == "ok":
		var hooks []any
		_ = json.Unmarshal([]byte(os.Getenv(fakeHooksEnv)), &hooks)
		return map[string]any{"id": id, "result": map[string]any{"data": []any{map[string]any{"cwd": "/x", "hooks": hooks}}}}
	case method == "config/batchWrite" && mode == "ok":
		return map[string]any{"id": id, "result": map[string]any{"status": "ok", "version": "v1"}}
	default:
		return map[string]any{"id": id, "error": map[string]any{"code": -32601, "message": "Method not found: " + method}}
	}
}

type fakeServer struct {
	log, pids string
	env       []string
}

func newFakeServer(t *testing.T, mode string, hooks []map[string]any) fakeServer {
	t.Helper()
	dir := t.TempDir()
	hooksJSON, err := json.Marshal(hooks)
	if err != nil {
		t.Fatal(err)
	}
	f := fakeServer{log: filepath.Join(dir, "requests.jsonl"), pids: filepath.Join(dir, "pids")}
	f.env = append(os.Environ(),
		fakeModeEnv+"="+mode, fakeLogEnv+"="+f.log, fakeHooksEnv+"="+string(hooksJSON), fakePIDsEnv+"="+f.pids)
	// Backstop for a test that fails before the code under test kills the
	// stub: the server leads its own process group (Setpgid), so killing the
	// group takes its sleep child too. StartAppServer owns and waits the
	// server; the child is reparented and reaped by init.
	t.Cleanup(func() {
		if b, err := os.ReadFile(f.pids); err == nil {
			if fields := strings.Fields(string(b)); len(fields) > 0 {
				if pgid, err := strconv.Atoi(fields[0]); err == nil && pgid > 1 {
					_ = syscall.Kill(-pgid, syscall.SIGKILL)
				}
			}
		}
	})
	return f
}

func (f fakeServer) start(t *testing.T) AppServer {
	t.Helper()
	srv, err := StartAppServer(context.Background(), os.Args[0], []string{"-c", "hooks.Stop=[]"}, f.env)
	if err != nil {
		t.Fatalf("StartAppServer: %v", err)
	}
	return srv
}

type loggedRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

func (f fakeServer) requests(t *testing.T) []loggedRequest {
	t.Helper()
	b, err := os.ReadFile(f.log)
	if err != nil {
		t.Fatal(err)
	}
	var out []loggedRequest
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var r loggedRequest
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("logged request %q: %v", line, err)
		}
		out = append(out, r)
	}
	return out
}

func (f fakeServer) methods(t *testing.T) []string {
	var ms []string
	for _, r := range f.requests(t) {
		ms = append(ms, r.Method)
	}
	return ms
}

func hookJSON(key, event, command, source, trust string) map[string]any {
	return map[string]any{
		"key": key, "eventName": event, "handlerType": "command", "command": command,
		"source": source, "currentHash": "sha256:" + key, "trustStatus": trust,
		"timeoutSec": 5, "enabled": true, "displayOrder": 0, "isManaged": false,
	}
}

const ourStart = "'/Users/example/bin/watchtower' workbench brief --agent codex"
const ourStop = "'/Users/example/bin/watchtower' workbench check --agent codex --stop-hook"

func TestAppServer_ListAndTrustRoundTrip(t *testing.T) {
	f := newFakeServer(t, "ok", []map[string]any{
		hookJSON("/<session-flags>/config.toml:session_start:0:0", "sessionStart", ourStart, "sessionFlags", "untrusted"),
		hookJSON("/<session-flags>/config.toml:stop:0:0", "stop", ourStop, "sessionFlags", "modified"),
	})
	srv := f.start(t)
	entries, err := srv.ListHooks(context.Background(), "/Users/example/proj")
	if err != nil {
		t.Fatalf("ListHooks: %v", err)
	}
	want := HookEntry{Key: "/<session-flags>/config.toml:session_start:0:0", Command: ourStart,
		CurrentHash: "sha256:/<session-flags>/config.toml:session_start:0:0", TrustStatus: "untrusted",
		Source: "sessionFlags", Event: "sessionStart"}
	if len(entries) != 2 || entries[0] != want {
		t.Fatalf("entries = %+v, want first %+v", entries, want)
	}
	if err := srv.TrustHooks(context.Background(), entries); err != nil {
		t.Fatalf("TrustHooks: %v", err)
	}
	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	reqs := f.requests(t)
	if got := f.methods(t); strings.Join(got, ",") != "initialize,initialized,hooks/list,config/batchWrite" {
		t.Fatalf("methods = %v", got)
	}
	assertJSON(t, reqs[2].Params, `{"cwds":["/Users/example/proj"]}`)
	assertJSON(t, reqs[3].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
		"/<session-flags>/config.toml:session_start:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:session_start:0:0"},
		"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
}

func TestAppServer_TrustSkipsForeignAndAlreadyTrusted(t *testing.T) {
	const foreign = "/usr/bin/true"
	f := newFakeServer(t, "ok", []map[string]any{
		hookJSON("/Users/example/proj/.codex/hooks.json:session_start:0:0", "sessionStart", ourStart, "project", "untrusted"),
		hookJSON("/<session-flags>/config.toml:session_start:0:0", "sessionStart", foreign, "sessionFlags", "untrusted"),
		hookJSON("/<session-flags>/config.toml:session_start:0:1", "sessionStart", ourStart, "sessionFlags", "trusted"),
		hookJSON("/<session-flags>/config.toml:stop:0:0", "stop", ourStop, "sessionFlags", "untrusted"),
	})
	srv := f.start(t)
	defer func() { _ = srv.Close() }()
	entries, err := srv.ListHooks(context.Background(), "/Users/example/proj")
	if err != nil {
		t.Fatal(err)
	}
	matched, missing := MatchSessionFlagHooks(entries, []HookRef{
		{Event: "SessionStart", Command: ourStart}, {Event: "Stop", Command: ourStop}, {Event: "PostToolUse", Command: ourStop},
	})
	if len(matched) != 2 || matched[0].Key != "/<session-flags>/config.toml:session_start:0:1" ||
		matched[1].Key != "/<session-flags>/config.toml:stop:0:0" {
		t.Fatalf("matched = %+v", matched)
	}
	if len(missing) != 1 || missing[0].Event != "PostToolUse" {
		t.Fatalf("missing = %+v", missing)
	}
	// Even handed every entry, TrustHooks writes only the untrusted
	// launch-flag ones: never a project hook, never a trusted one.
	if err := srv.TrustHooks(context.Background(), entries); err != nil {
		t.Fatal(err)
	}
	if err := srv.TrustHooks(context.Background(), matched); err != nil {
		t.Fatal(err)
	}
	reqs := f.requests(t)
	if len(reqs) != 5 {
		t.Fatalf("requests = %v", f.methods(t))
	}
	assertJSON(t, reqs[3].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
		"/<session-flags>/config.toml:session_start:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:session_start:0:0"},
		"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
	assertJSON(t, reqs[4].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
		"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
}

func TestAppServer_TrustNothingSendsNothing(t *testing.T) {
	f := newFakeServer(t, "ok", nil)
	srv := f.start(t)
	trusted := HookEntry{Key: "k", Command: ourStart, CurrentHash: "sha256:k", TrustStatus: "trusted", Source: "sessionFlags"}
	for _, entries := range [][]HookEntry{nil, {}, {trusted}} {
		if err := srv.TrustHooks(context.Background(), entries); err != nil {
			t.Fatal(err)
		}
	}
	if err := srv.Close(); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(f.methods(t), ","); got != "initialize,initialized" {
		t.Fatalf("methods = %s", got)
	}
}

func TestAppServer_ListEmptyIsNoHooks(t *testing.T) {
	srv := newFakeServer(t, "ok", nil).start(t)
	defer func() { _ = srv.Close() }()
	entries, err := srv.ListHooks(context.Background(), "/Users/example/proj")
	if err != nil || len(entries) != 0 {
		t.Fatalf("entries = %v, err = %v", entries, err)
	}
}

func TestAppServer_TimeoutKillsAndReturnsUnavailable(t *testing.T) {
	old := appServerBudget
	appServerBudget = 500 * time.Millisecond
	t.Cleanup(func() { appServerBudget = old })
	f := newFakeServer(t, "hang", nil)
	start := time.Now()
	_, err := StartAppServer(context.Background(), os.Args[0], nil, f.env)
	if !errors.Is(err, ErrCodexTrustUnavailable) {
		t.Fatalf("err = %v, want ErrCodexTrustUnavailable", err)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("took %s, want about the budget", d)
	}
	waitPIDsGone(t, f)
}

// waitGone fails unless pid exits (and is reaped by whoever owns it) soon.
func waitGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		if zombie(pid) {
			return // killed; its parent died with it, launchd reaps it
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("process %d still alive", pid)
}

func zombie(pid int) bool {
	out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	return err == nil && strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
}

// A cancelled caller (a SIGTERM routed into ctx) kills the server's process
// group at once, the budget notwithstanding: nothing it spawned survives.
func TestAppServer_CallerCancelKillsTheGroup(t *testing.T) {
	t.Run("while starting", func(t *testing.T) {
		f := newFakeServer(t, "hang", nil)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		// Cancel once the stub has spawned its child and written the pids —
		// a fixed delay raced the stub's own start-up (a -race test binary
		// re-exec can take longer than the delay), and a group killed before
		// the write leaves no pids to check. The "hang" stub never answers
		// initialize, so the cancel still lands while StartAppServer waits.
		cancelled := make(chan time.Time, 1)
		go func() {
			defer func() { cancelled <- time.Now(); cancel() }()
			deadline := time.Now().Add(10 * time.Second)
			for time.Now().Before(deadline) {
				if b, err := os.ReadFile(f.pids); err == nil && len(strings.Fields(string(b))) == 2 {
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
		}()
		_, err := StartAppServer(ctx, os.Args[0], nil, f.env)
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("err = %v", err)
		}
		if d := time.Since(<-cancelled); d > 5*time.Second {
			t.Fatalf("took %s after the cancel: the cancel did not end the wait", d)
		}
		waitPIDsGone(t, f)
	})
	t.Run("while idle", func(t *testing.T) {
		f := newFakeServer(t, "ok-child", nil)
		ctx, cancel := context.WithCancel(context.Background())
		srv, err := StartAppServer(ctx, os.Args[0], nil, f.env)
		if err != nil {
			t.Fatal(err)
		}
		cancel()
		waitPIDsGone(t, f) // before any Close
		_, err = srv.ListHooks(context.Background(), "/Users/example/proj")
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("ListHooks after cancel: %v", err)
		}
		_ = srv.Close()
	})
}

func waitPIDsGone(t *testing.T, f fakeServer) {
	t.Helper()
	b, err := os.ReadFile(f.pids)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range strings.Fields(string(b)) {
		pid, _ := strconv.Atoi(field)
		waitGone(t, pid)
	}
}

func TestAppServer_UnknownMethodErrorIsUnavailable(t *testing.T) {
	f := newFakeServer(t, "unknown-method", nil)
	srv := f.start(t)
	defer func() { _ = srv.Close() }()
	_, err := srv.ListHooks(context.Background(), "/Users/example/proj")
	if !errors.Is(err, ErrCodexTrustUnavailable) || !strings.Contains(err.Error(), "Method not found") {
		t.Fatalf("ListHooks err = %v", err)
	}
	err = srv.TrustHooks(context.Background(), []HookEntry{{Key: "k", CurrentHash: "h", TrustStatus: "untrusted", Source: "sessionFlags"}})
	if !errors.Is(err, ErrCodexTrustUnavailable) {
		t.Fatalf("TrustHooks err = %v", err)
	}
}

func TestAppServer_MissingBinaryIsUnavailable(t *testing.T) {
	_, err := StartAppServer(context.Background(), filepath.Join(t.TempDir(), "codex"), nil, os.Environ())
	if !errors.Is(err, ErrCodexTrustUnavailable) {
		t.Fatalf("err = %v", err)
	}
}

// An output line over the buffer stops the reader: the error names why,
// not only that the output closed.
func TestAppServer_OversizedLineSaysWhy(t *testing.T) {
	f := newFakeServer(t, "huge", nil)
	_, err := StartAppServer(context.Background(), os.Args[0], nil, f.env)
	if !errors.Is(err, ErrCodexTrustUnavailable) || !strings.Contains(err.Error(), "token too long") {
		t.Fatalf("err = %v", err)
	}
}

func TestAppServer_EarlyExitIsUnavailable(t *testing.T) {
	_, err := StartAppServer(context.Background(), "/usr/bin/true", nil, os.Environ())
	if !errors.Is(err, ErrCodexTrustUnavailable) {
		t.Fatalf("err = %v", err)
	}
}

func TestWireEventName(t *testing.T) {
	for in, want := range map[string]string{"SessionStart": "sessionStart", "Stop": "stop", "": ""} {
		if got := wireEventName(in); got != want {
			t.Errorf("wireEventName(%q) = %q, want %q", in, got, want)
		}
	}
}

func assertJSON(t *testing.T, got json.RawMessage, want string) {
	t.Helper()
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatalf("got %s: %v", got, err)
	}
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatalf("want %s: %v", want, err)
	}
	gb, _ := json.Marshal(g)
	wb, _ := json.Marshal(w)
	if string(gb) != string(wb) {
		t.Fatalf("params = %s\nwant     %s", gb, wb)
	}
}
