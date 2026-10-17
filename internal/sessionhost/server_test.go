package sessionhost

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const ioTimeout = 5 * time.Second

// socketPath returns a short socket path; t.TempDir paths can exceed the
// 104-byte unix socket limit.
func socketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

// startServer runs an in-process server and stops it in t.Cleanup.
func startServer(t *testing.T, opts Options) string {
	t.Helper()
	path := socketPath(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewServer(opts).Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(ioTimeout):
			t.Error("Serve did not return after cancel")
		}
	})
	return path
}

type client struct {
	t  *testing.T
	nc net.Conn
}

func dialRaw(t *testing.T, path string) *client {
	t.Helper()
	nc, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = nc.Close() })
	return &client{t: t, nc: nc}
}

// dial connects and completes Hello.
func dial(t *testing.T, path string) *client {
	t.Helper()
	c := dialRaw(t, path)
	c.send(Hello, HelloMsg{Version: ProtocolVersion})
	if ft, _ := c.read(); ft != HelloOK {
		t.Fatalf("hello reply = %#x, want HelloOK", ft)
	}
	return c
}

func (c *client) send(ft FrameType, v any) {
	c.t.Helper()
	var p []byte
	switch x := v.(type) {
	case nil:
	case []byte:
		p = x
	default:
		var err error
		if p, err = json.Marshal(v); err != nil {
			c.t.Fatal(err)
		}
	}
	if err := WriteFrame(c.nc, ft, p); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) readErr() (FrameType, []byte, error) {
	_ = c.nc.SetReadDeadline(time.Now().Add(ioTimeout))
	return ReadFrame(c.nc)
}

func (c *client) read() (FrameType, []byte) {
	c.t.Helper()
	ft, p, err := c.readErr()
	if err != nil {
		c.t.Fatalf("read frame: %v", err)
	}
	return ft, p
}

// expect skips Output frames until a frame of type want arrives.
func (c *client) expect(want FrameType) []byte {
	c.t.Helper()
	for {
		ft, p := c.read()
		if ft == want {
			return p
		}
		if ft != Output {
			c.t.Fatalf("got frame %#x (%s), want %#x", ft, p, want)
		}
	}
}

// outputUntil reads Output frames until their concatenation satisfies ok.
func (c *client) outputUntil(ok func(string) bool) string {
	c.t.Helper()
	var sb strings.Builder
	for !ok(sb.String()) {
		ft, p := c.read()
		if ft != Output {
			c.t.Fatalf("got frame %#x (%s) while waiting for output %q", ft, p, sb.String())
		}
		sb.Write(p)
	}
	return sb.String()
}

func (c *client) list() []SessionInfo {
	c.t.Helper()
	c.send(List, nil)
	var resp ListResp
	if err := json.Unmarshal(c.expect(Listed), &resp); err != nil {
		c.t.Fatal(err)
	}
	return resp.Sessions
}

// launch starts a /bin/sh -c script session; t.Cleanup kills its process
// group and waits until the host has reaped it.
func (c *client) launch(row int64, script string, env ...string) SessionInfo {
	c.t.Helper()
	c.send(Launch, LaunchReq{
		Row: row, Run: "r1", Executable: "/bin/sh", Args: []string{"-c", script},
		Env: env, Cwd: os.TempDir(), Cols: 80, Rows: 24,
	})
	var info SessionInfo
	if err := json.Unmarshal(c.expect(Launched), &info); err != nil {
		c.t.Fatal(err)
	}
	if info.Pid > 0 {
		c.t.Cleanup(func() { reap(c.t, info.Pid) })
	} else {
		c.t.Fatalf("launched pid = %d", info.Pid)
	}
	return info
}

// reap kills pid's process group and waits until the host reaped the child.
func reap(t *testing.T, pid int) {
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	deadline := time.Now().Add(ioTimeout)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			t.Errorf("child %d still alive after SIGKILL", pid)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func errMsg(t *testing.T, p []byte) string {
	t.Helper()
	var m ErrorMsg
	if err := json.Unmarshal(p, &m); err != nil {
		t.Fatal(err)
	}
	return m.Message
}

func TestSessionHost20_SessionSurvivesClientDisconnect(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	info := c1.launch(1, `while :; do echo tick; sleep 0.1; done`)
	_ = c1.nc.Close()
	time.Sleep(300 * time.Millisecond)

	c2 := dial(t, path)
	got := c2.list()
	if len(got) != 1 || got[0].Exited || got[0].Pid != info.Pid {
		t.Fatalf("list = %+v, want one running session pid %d", got, info.Pid)
	}
	if err := syscall.Kill(info.Pid, 0); err != nil {
		t.Fatalf("child gone after disconnect: %v", err)
	}
	c3 := dial(t, path)
	c3.send(Attach, AttachReq{Row: 1, Run: "r1"})
	c3.expect(Attached)
	c3.outputUntil(func(s string) bool { return strings.Contains(s, "tick") })
}

func TestServer_ScopeRoundTrips(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.send(Launch, LaunchReq{
		Row: 1, Run: "r1", Executable: "/bin/sh", Args: []string{"-c", "sleep 30"},
		Cwd: os.TempDir(), Cols: 80, Rows: 24, Scope: "ws-a",
	})
	var launched SessionInfo
	if err := json.Unmarshal(c.expect(Launched), &launched); err != nil {
		t.Fatal(err)
	}
	if launched.Pid <= 0 {
		t.Fatalf("launched pid = %d", launched.Pid)
	}
	t.Cleanup(func() { reap(t, launched.Pid) })
	if launched.Scope != "ws-a" {
		t.Fatalf("launched scope = %q, want ws-a", launched.Scope)
	}
	got := dial(t, path).list()
	if len(got) != 1 || got[0].Scope != "ws-a" {
		t.Fatalf("list = %+v, want one session of scope ws-a", got)
	}
	a := dial(t, path)
	a.send(Attach, AttachReq{Row: 1, Run: "r1"})
	var attached SessionInfo
	if err := json.Unmarshal(a.expect(Attached), &attached); err != nil {
		t.Fatal(err)
	}
	if attached.Scope != "ws-a" {
		t.Fatalf("attached scope = %q, want ws-a", attached.Scope)
	}
}

func TestServer_LaunchUsesOnlyGivenEnv(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.launch(1, `echo "$FOO-$HOME-"`, "FOO=bar")
	c.outputUntil(func(s string) bool { return strings.Contains(s, "bar--") })
}

func TestServer_ExitWhileDetachedIsKeptUntilForget(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	c1.launch(1, `sleep 0.2; exit 7`)
	_ = c1.nc.Close()
	time.Sleep(500 * time.Millisecond)

	c2 := dial(t, path)
	got := c2.list()
	if len(got) != 1 || !got[0].Exited || got[0].Code == nil || *got[0].Code != 7 {
		t.Fatalf("list = %+v, want one exited session with code 7", got)
	}
	c2.send(Forget, AttachReq{Row: 1, Run: "r1"})
	c2.expect(Forgot)
	if got := c2.list(); len(got) != 0 {
		t.Fatalf("list after forget = %+v, want empty", got)
	}
}

// A delivered exit may still be lost on its way; the record stays until
// the client forgets it.
func TestServer_ExitWhileAttachedIsKeptUntilForget(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.launch(1, `sleep 0.1; exit 3`)
	var msg ExitMsg
	if err := json.Unmarshal(c.expect(Exit), &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Code == nil || *msg.Code != 3 {
		t.Fatalf("exit code = %v, want 3", msg.Code)
	}
	ctl := dial(t, path)
	if got := ctl.list(); len(got) != 1 || !got[0].Exited || got[0].Code == nil || *got[0].Code != 3 {
		t.Fatalf("list = %+v, want the exited run with code 3", got)
	}
	ctl.send(Forget, AttachReq{Row: 1, Run: "r1"})
	ctl.expect(Forgot)
	if got := ctl.list(); len(got) != 0 {
		t.Fatalf("list after forget = %+v, want empty", got)
	}
}

func TestServer_ExitBySignalHasNullCode(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	info := c.launch(1, `echo up; sleep 5`)
	c.outputUntil(func(s string) bool { return strings.Contains(s, "up") })
	_ = syscall.Kill(-info.Pid, syscall.SIGKILL)
	p := c.expect(Exit)
	if string(p) != `{"code":null}` {
		t.Fatalf("exit payload = %s, want {\"code\":null}", p)
	}
}

func TestServer_ResizeSendsSigwinch(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.launch(1, `trap "echo W" WINCH; echo ready; while :; do sleep 0.05; done`)
	c.outputUntil(func(s string) bool { return strings.Contains(s, "ready") })
	// Same size both times; the second waits for the first trap because
	// pending signals coalesce.
	for range 2 {
		c.send(Resize, ResizeReq{Cols: 80, Rows: 24})
		c.outputUntil(func(s string) bool { return strings.Contains(s, "W") })
	}
}

func TestServer_AttachTakesOver(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	c1.launch(1, `while :; do echo tick; sleep 0.1; done`)
	c2 := dial(t, path)
	c2.send(Attach, AttachReq{Row: 1, Run: "r1"})
	c2.expect(Attached)
	if msg := errMsg(t, c1.expect(Error)); msg != TakenOver {
		t.Fatalf("first connection error = %q, want %q", msg, TakenOver)
	}
	ft, p, err := c1.readErr()
	if err == nil {
		t.Fatalf("first connection got frame %#x (%s) after the takeover error, want EOF", ft, p)
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		t.Fatal("first connection still open after takeover")
	}
	c2.outputUntil(func(s string) bool { return strings.Contains(s, "tick") })
}

func TestServer_AttachReplaysModes(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	c1.launch(1, `printf '\033[?2004h'; echo hi; sleep 5`)
	c1.outputUntil(func(s string) bool { return strings.Contains(s, "hi") })
	_ = c1.nc.Close()

	c2 := dial(t, path)
	c2.send(Attach, AttachReq{Row: 1, Run: "r1"})
	c2.expect(Attached)
	ft, p := c2.read()
	if ft != Output || !strings.HasPrefix(string(p), "\x1b[?2004h") || !strings.Contains(string(p), "hi") {
		t.Fatalf("replay = %#x %q, want the mode prefix then the tail", ft, p)
	}
}

func TestServer_AttachExitedSession(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	c1.launch(1, `echo last words; exit 4`)
	_ = c1.nc.Close()
	c2 := dial(t, path)
	deadline := time.Now().Add(ioTimeout)
	for got := c2.list(); len(got) != 1 || !got[0].Exited; got = c2.list() {
		if time.Now().After(deadline) {
			t.Fatalf("session never exited: %+v", got)
		}
		time.Sleep(20 * time.Millisecond)
	}
	c2.send(Attach, AttachReq{Row: 1, Run: "r1"})
	var info SessionInfo
	if err := json.Unmarshal(c2.expect(Attached), &info); err != nil {
		t.Fatal(err)
	}
	if !info.Exited || info.Code == nil || *info.Code != 4 {
		t.Fatalf("attached = %+v, want exited with code 4", info)
	}
	ft, p := c2.read()
	if ft != Output || !strings.Contains(string(p), "last words") {
		t.Fatalf("after Attached got %#x %q, want the replay", ft, p)
	}
	if p := c2.expect(Exit); string(p) != `{"code":4}` {
		t.Fatalf("exit payload = %s", p)
	}
}

func TestServer_Errors(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.send(Attach, AttachReq{Row: 9, Run: "nope"})
	if msg := errMsg(t, c.expect(Error)); !strings.Contains(msg, "no session") {
		t.Fatalf("attach unknown: %q", msg)
	}
	c.launch(1, `sleep 5`)
	c2 := dial(t, path)
	c2.send(Forget, AttachReq{Row: 1, Run: "r1"})
	if msg := errMsg(t, c2.expect(Error)); !strings.Contains(msg, "running") {
		t.Fatalf("forget running: %q", msg)
	}
}

func TestServer_UnknownFrameIsSkipped(t *testing.T) {
	path := startServer(t, Options{})
	c := dial(t, path)
	c.send(FrameType(0x7E), []byte("from a newer app"))
	if got := c.list(); len(got) != 0 {
		t.Fatalf("list = %+v", got)
	}
}

func TestServer_HelloVersionMismatchCloses(t *testing.T) {
	path := startServer(t, Options{})
	c := dialRaw(t, path)
	c.send(Hello, HelloMsg{Version: 2})
	if ft, _ := c.read(); ft != Error {
		t.Fatalf("reply = %#x, want Error", ft)
	}
	if _, _, err := c.readErr(); err == nil {
		t.Fatal("connection still open after a version mismatch")
	}
}

func TestServer_IdleExit(t *testing.T) {
	path := socketPath(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- NewServer(Options{IdleExit: 200 * time.Millisecond}).Serve(context.Background(), l) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Serve = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Serve did not exit when idle")
	}
}

// The app's control connection is bound to no session: it does not keep an
// idle host alive, so a newer host binary can take over.
func TestServer_IdleExitIgnoresUnboundConnection(t *testing.T) {
	path := socketPath(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- NewServer(Options{IdleExit: 200 * time.Millisecond}).Serve(context.Background(), l) }()
	c := dial(t, path)
	if got := c.list(); len(got) != 0 {
		t.Fatalf("list = %+v", got)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Serve = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not exit with only an unbound connection open")
	}
}

// A connection attached to a session keeps the host up.
func TestServer_IdleExitWaitsForBoundConnection(t *testing.T) {
	path := socketPath(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewServer(Options{IdleExit: 200 * time.Millisecond}).Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	c := dial(t, path)
	c.launch(1, `exit 0`)
	c.expect(Exit)
	ctl := dial(t, path)
	ctl.send(Forget, AttachReq{Row: 1, Run: "r1"})
	ctl.expect(Forgot)
	select {
	case err := <-done:
		t.Fatalf("Serve returned (%v) while a connection is still bound", err)
	case <-time.After(600 * time.Millisecond):
	}
	_ = c.nc.Close()
	select {
	case err := <-done:
		done <- err // for the cleanup
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not exit after the bound connection closed")
	}
}

func TestListen_StaleSocketIsReplaced(t *testing.T) {
	path := socketPath(t)
	old, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	old.(*net.UnixListener).SetUnlinkOnClose(false)
	_ = old.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stale socket missing: %v", err)
	}
	l, err := Listen(path)
	if err != nil {
		t.Fatalf("Listen over a stale socket: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %v, want 0600", fi.Mode().Perm())
	}
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial re-bound socket: %v", err)
	}
	_ = c.Close()
}

func TestListen_LiveHostReturnsErrHostRunning(t *testing.T) {
	path := socketPath(t)
	l, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	if _, err := Listen(path); !errors.Is(err, ErrHostRunning) {
		t.Fatalf("second Listen = %v, want ErrHostRunning", err)
	}
	// A live listener that holds no lock file is still detected by
	// dialing it.
	path2 := socketPath(t)
	raw, err := net.Listen("unix", path2)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	if _, err := Listen(path2); !errors.Is(err, ErrHostRunning) {
		t.Fatalf("Listen on a live socket = %v, want ErrHostRunning", err)
	}
}

func TestServer_HostedChildKeepsDefaultSighup(t *testing.T) {
	// The host process catches SIGHUP the way the CLI does; a hosted child
	// must still die of SIGHUP rather than inherit an ignored disposition.
	t.Cleanup(DiscardHangup())
	path := startServer(t, Options{})
	c := dial(t, path)
	c.launch(1, `kill -HUP $$; echo survived`)
	out := ""
	for {
		ft, p := c.read()
		if ft == Exit {
			if string(p) != `{"code":null}` {
				t.Fatalf("exit = %s, want killed by a signal", p)
			}
			break
		}
		if ft != Output {
			t.Fatalf("got frame %#x", ft)
		}
		out += string(p)
	}
	if strings.Contains(out, "survived") {
		t.Fatalf("child survived SIGHUP: %q", out)
	}
}
