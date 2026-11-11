package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/codex/codextest"
	"watchtower/internal/llmusage"
)

// The process fake is this test binary re-run with fakeModeEnv set: TestMain
// then serves stdin instead of running tests. Only the process wiring tests
// start it; every conversation test serves the protocol in-process
// (codextest) under testing/synctest.
const (
	fakeModeEnv  = "WT_FAKE_APPSERVER_MODE"  // ok | usage
	fakeHooksEnv = "WT_FAKE_APPSERVER_HOOKS" // ok: hooks/list's hooks, a JSON array
	fakeFIFOEnv  = "WT_FAKE_APPSERVER_FIFO"  // a FIFO the server and its child hold open for writing
	// fakeTestPIDEnv is the test binary's pid: the server's child lives while it does.
	fakeTestPIDEnv = "WT_FAKE_APPSERVER_TEST_PID"
)

func TestMain(m *testing.M) {
	if mode := os.Getenv(fakeModeEnv); mode != "" {
		os.Exit(runFakeAppServer(mode))
	}
	if nonce := os.Getenv(liveMCPNonceEnv); nonce != "" && len(os.Args) > 1 && os.Args[1] == "mcp" {
		os.Exit(runFakeMCPServer(nonce)) // live_test.go: mounted as the watchtower server
	}
	liveCodexHome = os.Getenv("CODEX_HOME")
	// No test runs a real `codex --version`: every binary counts as one
	// with model_instructions_file, except where a test restores the real
	// probe against a fake codex (instructions_test.go).
	probeCodexVersion = func(string) ([3]int, error) { return minInstructionsFileVersion, nil }
	// Hermetic codex config layers: never the developer's own ~/.codex or
	// /etc/codex (ownerServerNames); a test that needs owner servers sets
	// CODEX_HOME itself.
	home, err := os.MkdirTemp("", "codex-test-home-*")
	if err != nil {
		os.Exit(2)
	}
	_ = os.Setenv("CODEX_HOME", home)
	systemConfigDir = home + "/no-system-config"
	llmusage.SetSink(discardSink{}) // codex_llmusage_test.go
	code := m.Run()
	_ = os.RemoveAll(home)
	os.Exit(code)
}

// runFakeAppServer is the process fake. Before answering anything it opens
// the FIFO for writing and starts a child that holds it too, so the test
// sees the server's whole group gone as the FIFO's EOF.
func runFakeAppServer(mode string) int {
	if path := os.Getenv("WT_USAGE_CWD"); path != "" {
		cwd, _ := os.Getwd()
		_ = os.WriteFile(path, []byte(cwd), 0o600)
	}
	if path := os.Getenv(fakeFIFOEnv); path != "" {
		fifo, err := os.OpenFile(path, os.O_WRONLY, 0)
		if err != nil {
			return 2
		}
		// The child outlives the server (only the group kill ends it) but
		// not the test binary: a run go test -timeout ends leaves nothing.
		child := exec.Command("/bin/sh", "-c", `while kill -0 "$`+fakeTestPIDEnv+`" 2>/dev/null; do sleep 1; done`)
		child.ExtraFiles = []*os.File{fifo}
		if err := child.Start(); err != nil {
			return 2
		}
	}
	handle := okServer(nil)
	if mode == "ok" {
		var hooks []map[string]any
		_ = json.Unmarshal([]byte(os.Getenv(fakeHooksEnv)), &hooks)
		handle = okServer(hooks)
	} else if mode == "usage" {
		handle = usageServer(json.RawMessage(os.Getenv("WT_USAGE_ACCOUNT")), json.RawMessage(os.Getenv("WT_USAGE_LIMITS")))
	}
	out := bufio.NewWriter(os.Stdout)
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		var m codextest.Message
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		for _, reply := range handle(m) {
			b, _ := json.Marshal(reply)
			_, _ = out.Write(append(b, '\n'))
		}
		_ = out.Flush()
	}
	return 0
}

// notice is a server notification, as the real server sends them unasked.
var notice = map[string]any{"jsonrpc": "2.0", "method": "remoteControl/status/changed", "params": map[string]any{}}

func isRequest(m codextest.Message) bool { return len(m.ID) > 0 && string(m.ID) != "null" }

// okServer answers initialize, hooks/list (with hooks) and config/batchWrite;
// any other method is unknown.
func okServer(hooks []map[string]any) codextest.Handler {
	return func(m codextest.Message) []any {
		if !isRequest(m) {
			return nil
		}
		switch m.Method {
		case "initialize":
			return []any{notice, codextest.Result(m, map[string]any{"userAgent": "fake/0"})}
		case "hooks/list":
			return []any{notice, codextest.Result(m, map[string]any{"data": []any{map[string]any{"cwd": "/x", "hooks": hooks}}})}
		case "config/batchWrite":
			return []any{codextest.Result(m, map[string]any{"status": "ok", "version": "v1"})}
		}
		return []any{codextest.Error(m, -32601, "Method not found: "+m.Method)}
	}
}

// unknownMethodServer knows initialize only.
func unknownMethodServer(m codextest.Message) []any {
	if isRequest(m) && m.Method == "initialize" {
		return []any{codextest.Result(m, map[string]any{})}
	}
	if isRequest(m) {
		return []any{codextest.Error(m, -32601, "Method not found: "+m.Method)}
	}
	return nil
}

// silentServer never answers.
func silentServer(codextest.Message) []any { return nil }

// fakeConn serves handle in-process; the launcher hands it out once.
func fakeConn(handle codextest.Handler) (*codextest.Server, appServerLauncher) {
	s := codextest.New(handle)
	return s, func() (AppServerConn, error) { return s.Serve(), nil }
}

// startFake runs StartAppServer's conversation against an in-process server.
func startFake(t *testing.T, ctx context.Context, handle codextest.Handler) (*codextest.Server, AppServer, error) {
	t.Helper()
	s, launch := fakeConn(handle)
	srv, err := startAppServer(ctx, launch, appServerBudget)
	return s, srv, err
}

// startHung is startFake against a hung server: it ignores its input's EOF
// too, so only a kill ends it — Killed then says the kill happened.
func startHung(t *testing.T, ctx context.Context, handle codextest.Handler) (*codextest.Server, error) {
	t.Helper()
	s, launch := fakeConn(handle)
	s.Linger = true
	_, err := startAppServer(ctx, launch, appServerBudget)
	return s, err
}

type loggedRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

func requests(t *testing.T, s *codextest.Server) []loggedRequest {
	t.Helper()
	var out []loggedRequest
	for _, line := range s.Lines() {
		var r loggedRequest
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("logged request %q: %v", line, err)
		}
		out = append(out, r)
	}
	return out
}

func methods(t *testing.T, s *codextest.Server) string {
	var ms []string
	for _, r := range requests(t, s) {
		ms = append(ms, r.Method)
	}
	return strings.Join(ms, ",")
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
	synctest.Test(t, func(t *testing.T) {
		fake, srv, err := startFake(t, context.Background(), okServer([]map[string]any{
			hookJSON("/<session-flags>/config.toml:session_start:0:0", "sessionStart", ourStart, "sessionFlags", "untrusted"),
			hookJSON("/<session-flags>/config.toml:stop:0:0", "stop", ourStop, "sessionFlags", "modified"),
		}))
		if err != nil {
			t.Fatalf("StartAppServer: %v", err)
		}
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
		if fake.Killed() {
			t.Fatal("the server was killed instead of exiting at EOF")
		}
		reqs := requests(t, fake)
		if got := methods(t, fake); got != "initialize,initialized,hooks/list,config/batchWrite" {
			t.Fatalf("methods = %v", got)
		}
		assertJSON(t, reqs[2].Params, `{"cwds":["/Users/example/proj"]}`)
		assertJSON(t, reqs[3].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
			"/<session-flags>/config.toml:session_start:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:session_start:0:0"},
			"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
	})
}

func TestAppServer_TrustSkipsForeignAndAlreadyTrusted(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		const foreign = "/usr/bin/true"
		fake, srv, err := startFake(t, context.Background(), okServer([]map[string]any{
			hookJSON("/Users/example/proj/.codex/hooks.json:session_start:0:0", "sessionStart", ourStart, "project", "untrusted"),
			hookJSON("/<session-flags>/config.toml:session_start:0:0", "sessionStart", foreign, "sessionFlags", "untrusted"),
			hookJSON("/<session-flags>/config.toml:session_start:0:1", "sessionStart", ourStart, "sessionFlags", "trusted"),
			hookJSON("/<session-flags>/config.toml:stop:0:0", "stop", ourStop, "sessionFlags", "untrusted"),
		}))
		if err != nil {
			t.Fatal(err)
		}
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
		reqs := requests(t, fake)
		if len(reqs) != 5 {
			t.Fatalf("requests = %v", methods(t, fake))
		}
		assertJSON(t, reqs[3].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
			"/<session-flags>/config.toml:session_start:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:session_start:0:0"},
			"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
		assertJSON(t, reqs[4].Params, `{"edits":[{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{
			"/<session-flags>/config.toml:stop:0:0":{"trusted_hash":"sha256:/<session-flags>/config.toml:stop:0:0"}}}]}`)
	})
}

func TestAppServer_TrustNothingSendsNothing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		fake, srv, err := startFake(t, context.Background(), okServer(nil))
		if err != nil {
			t.Fatal(err)
		}
		trusted := HookEntry{Key: "k", Command: ourStart, CurrentHash: "sha256:k", TrustStatus: "trusted", Source: "sessionFlags"}
		for _, entries := range [][]HookEntry{nil, {}, {trusted}} {
			if err := srv.TrustHooks(context.Background(), entries); err != nil {
				t.Fatal(err)
			}
		}
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
		if got := methods(t, fake); got != "initialize,initialized" {
			t.Fatalf("methods = %s", got)
		}
	})
}

func TestAppServer_ListEmptyIsNoHooks(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		_, srv, err := startFake(t, context.Background(), okServer(nil))
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = srv.Close() }()
		entries, err := srv.ListHooks(context.Background(), "/Users/example/proj")
		if err != nil || len(entries) != 0 {
			t.Fatalf("entries = %v, err = %v", entries, err)
		}
	})
}

// A server that never answers is killed when the budget runs out — exactly
// then, in the bubble's time — and the start fails as unavailable.
func TestAppServer_TimeoutKillsAndReturnsUnavailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		fake, err := startHung(t, context.Background(), silentServer)
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("err = %v, want ErrCodexTrustUnavailable", err)
		}
		if d := time.Since(start); d != appServerBudget {
			t.Fatalf("took %s, want the budget (%s)", d, appServerBudget)
		}
		if !fake.Killed() {
			t.Fatal("the server outlived the budget")
		}
		<-fake.Exited()
	})
}

// A cancelled caller (a SIGTERM routed into ctx) kills the server at once,
// the budget notwithstanding.
func TestAppServer_CallerCancelKillsTheServer(t *testing.T) {
	t.Run("while starting", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			// The server takes initialize and never answers; the cancel
			// lands while StartAppServer waits for the answer.
			start := time.Now()
			fake, err := startHung(t, ctx, func(m codextest.Message) []any {
				if m.Method == "initialize" {
					cancel()
				}
				return nil
			})
			if !errors.Is(err, ErrCodexTrustUnavailable) {
				t.Fatalf("err = %v", err)
			}
			if d := time.Since(start); d != 0 {
				t.Fatalf("took %s after the cancel: the cancel did not end the wait", d)
			}
			if !fake.Killed() {
				t.Fatal("the server outlived the cancel")
			}
		})
	})
	t.Run("while idle", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			fake, srv, err := startFake(t, ctx, okServer(nil))
			if err != nil {
				t.Fatal(err)
			}
			cancel()
			synctest.Wait()
			if !fake.Killed() { // before any Close
				t.Fatal("the idle server outlived the cancel")
			}
			_, err = srv.ListHooks(context.Background(), "/Users/example/proj")
			if !errors.Is(err, ErrCodexTrustUnavailable) {
				t.Fatalf("ListHooks after cancel: %v", err)
			}
			_ = srv.Close()
		})
	})
}

// A server that does not exit at EOF is waited for within the budget only,
// then killed; Close says so.
func TestAppServer_CloseKillsAServerThatStays(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s, launch := fakeConn(okServer(nil))
		s.Linger = true
		srv, err := startAppServer(context.Background(), launch, appServerBudget)
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		err = srv.Close()
		if !errors.Is(err, ErrCodexTrustUnavailable) || !strings.Contains(err.Error(), "did not exit within 10s") {
			t.Fatalf("Close = %v", err)
		}
		if time.Since(start) != appServerBudget || !s.Killed() {
			t.Fatalf("Close waited %s, killed %v", time.Since(start), s.Killed())
		}
	})
}

func TestAppServer_UnknownMethodErrorIsUnavailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		_, srv, err := startFake(t, context.Background(), unknownMethodServer)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = srv.Close() }()
		_, err = srv.ListHooks(context.Background(), "/Users/example/proj")
		if !errors.Is(err, ErrCodexTrustUnavailable) || !strings.Contains(err.Error(), "Method not found") {
			t.Fatalf("ListHooks err = %v", err)
		}
		err = srv.TrustHooks(context.Background(), []HookEntry{{Key: "k", CurrentHash: "h", TrustStatus: "untrusted", Source: "sessionFlags"}})
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("TrustHooks err = %v", err)
		}
	})
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
	synctest.Test(t, func(t *testing.T) {
		huge := append([]byte(strings.Repeat("x", 17<<20)), '\n') // one line over the client's 16 MiB buffer
		_, _, err := startFake(t, context.Background(), func(m codextest.Message) []any {
			if isRequest(m) {
				return []any{huge}
			}
			return nil
		})
		if !errors.Is(err, ErrCodexTrustUnavailable) || !strings.Contains(err.Error(), "token too long") {
			t.Fatalf("err = %v", err)
		}
	})
}

// A server gone before it answered anything: unavailable, not a hang (the
// real process: TestAppServer_ProcessWiring "early exit").
func TestAppServer_EarlyExitIsUnavailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := codextest.New(silentServer)
		s.Kill()
		_, err := startAppServer(context.Background(), func() (AppServerConn, error) { return s.Serve(), nil }, appServerBudget)
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("err = %v", err)
		}
	})
}

// noBudget leaves a process wiring test without a budget: what it waits on
// are the process's own events, and a hang is go test -timeout's to end.
const noBudget = time.Duration(math.MaxInt64)

// heldFIFO makes a FIFO for the process fake to hold (fakeFIFOEnv) and opens
// its read end; gone returns once every writer — the server and its child —
// has closed it, i.e. the whole group is dead. A process event, no clock.
func heldFIFO(t *testing.T) (env string, gone func()) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "held")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	// Opened non-blocking, so the open needs no writer yet (the server's
	// blocking open for writing then succeeds at once); read blocking.
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.SetNonblock(fd, false); err != nil {
		t.Fatal(err)
	}
	r := os.NewFile(uintptr(fd), path)
	t.Cleanup(func() { _ = r.Close() })
	return fakeFIFOEnv + "=" + path, func() {
		if _, err := io.Copy(io.Discard, r); err != nil {
			t.Fatalf("reading the FIFO: %v", err)
		}
	}
}

// The real process: pipes, its own process group, EOF on Close and the group
// kill — on Close and on a cancelled caller. Only process events are waited
// on: the answers, the exit, the FIFO's EOF.
func TestAppServer_ProcessWiring(t *testing.T) {
	hooks, err := json.Marshal([]map[string]any{hookJSON("k", "stop", ourStop, "sessionFlags", "untrusted")})
	if err != nil {
		t.Fatal(err)
	}
	launch := func(t *testing.T) (appServerLauncher, func()) {
		fifo, gone := heldFIFO(t)
		env := append(os.Environ(), fakeModeEnv+"=ok", fakeHooksEnv+"="+string(hooks), fifo,
			fakeTestPIDEnv+"="+strconv.Itoa(os.Getpid()))
		return appServerProcess(os.Args[0], []string{"-c", "hooks.Stop=[]"}, env, ""), gone
	}
	t.Run("close", func(t *testing.T) {
		l, gone := launch(t)
		srv, err := startAppServer(context.Background(), l, noBudget)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = srv.Close() }) // kills the group on a failure path too
		entries, err := srv.ListHooks(context.Background(), "/Users/example/proj")
		if err != nil || len(entries) != 1 || entries[0].Key != "k" {
			t.Fatalf("entries = %+v, err = %v", entries, err)
		}
		if err := srv.Close(); err != nil {
			t.Fatal(err)
		}
		gone()
	})
	t.Run("cancel", func(t *testing.T) {
		l, gone := launch(t)
		ctx, cancel := context.WithCancel(context.Background())
		srv, err := startAppServer(ctx, l, noBudget)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = srv.Close() })
		cancel()
		gone() // before any Close
		if _, err := srv.ListHooks(context.Background(), "/Users/example/proj"); !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("ListHooks after cancel: %v", err)
		}
	})
	t.Run("early exit", func(t *testing.T) {
		// A real child gone before answering: its pipes close under the
		// client (EPIPE on the write, EOF on the read).
		_, err := startAppServer(context.Background(), appServerProcess("/usr/bin/true", nil, os.Environ(), ""), noBudget)
		if !errors.Is(err, ErrCodexTrustUnavailable) {
			t.Fatalf("err = %v", err)
		}
	})
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
