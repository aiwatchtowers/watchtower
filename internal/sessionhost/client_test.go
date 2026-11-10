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

// asHostEnv makes the test binary run as `session-host --socket PATH`, so
// Ensure can start it like the real CLI.
const asHostEnv = "SESSIONHOST_TEST_AS_HOST"

func TestMain(m *testing.M) {
	if os.Getenv(asHostEnv) == "1" {
		os.Exit(runTestHost(os.Args[1:]))
	}
	os.Exit(m.Run())
}

func runTestHost(args []string) int {
	if len(args) != 3 || args[0] != "session-host" || args[1] != "--socket" {
		return 2
	}
	l, err := Listen(args[2])
	if err != nil {
		return 1
	}
	if err := NewServer(Options{IdleExit: 2 * time.Second}).Serve(context.Background(), l); err != nil {
		return 1
	}
	return 0
}

// fakeV1Host serves socket like a released v1 host: a v2 hello is refused
// with its fixed message, a v1 hello gets HelloOK version 1.
func fakeV1Host(t *testing.T) string {
	t.Helper()
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	go func() {
		for {
			nc, err := l.Accept()
			if err != nil {
				return
			}
			go func(nc net.Conn) {
				defer func() { _ = nc.Close() }()
				_ = nc.SetDeadline(time.Now().Add(ioTimeout))
				_, _, _ = ReadFrame(nc)
				_ = WriteFrame(nc, Error, encode(ErrorMsg{Message: "unsupported protocol version 2 (host speaks 1)"}))
			}(nc)
		}
	}()
	return path
}

func ctxT(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), ioTimeout)
	t.Cleanup(cancel)
	return ctx
}

func TestClientRefusesV1Host(t *testing.T) {
	_, err := Dial(ctxT(t), fakeV1Host(t))
	if !errors.Is(err, ErrHostV1) {
		t.Fatalf("Dial v1 host = %v, want ErrHostV1", err)
	}

	// A host answering HelloOK with version 1 is refused too.
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	go func() {
		nc, err := l.Accept()
		if err != nil {
			return
		}
		defer func() { _ = nc.Close() }()
		_, _, _ = ReadFrame(nc)
		_ = WriteFrame(nc, HelloOK, encode(HelloMsg{Version: 1, Pid: 1}))
		_, _, _ = ReadFrame(nc) // hold until the client hangs up
	}()
	if _, err := Dial(ctxT(t), path); !errors.Is(err, ErrHostV1) {
		t.Fatalf("Dial HelloOK v1 = %v, want ErrHostV1", err)
	}
}

func TestClientLaunchInputStopForget(t *testing.T) {
	path := startServer(t, Options{})
	ctx := ctxT(t)
	cl, err := Dial(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cl.Close() })
	if cl.Pid() != os.Getpid() {
		t.Fatalf("host pid = %d", cl.Pid())
	}

	info, err := cl.Launch(ctx, LaunchReq{
		Row: 7, Run: "r1", Executable: "/bin/sh", Args: []string{"-c", "exec cat"},
		Cwd: os.TempDir(), Cols: 80, Rows: 24, Scope: "ws-a", Agent: "codex",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reap(t, info.Pid) })
	if info.Launch != 1 || info.Agent != "codex" || info.Scope != "ws-a" {
		t.Fatalf("launched = %+v", info)
	}

	// The client launched detached: a pane attaches without taking anything
	// over and sees what the client types.
	pane := dial(t, path)
	pane.send(Attach, AttachReq{Row: 7, Run: "r1"})
	pane.expect(Attached)
	if err := cl.InputTo(ctx, InputToReq{Row: 7, Run: "r1", Launch: info.Launch, Data: []byte("typed\n")}); err != nil {
		t.Fatal(err)
	}
	pane.outputUntil(func(s string) bool { return strings.Contains(s, "typed") })

	err = cl.InputTo(ctx, InputToReq{Row: 7, Run: "r1", Launch: info.Launch + 1, Data: []byte("x")})
	var he *HostError
	if !errors.As(err, &he) || !strings.Contains(he.Message, "launch") {
		t.Fatalf("InputTo wrong launch = %v, want a host error", err)
	}
	if err := cl.PromptHint(ctx, PromptHintMsg{Row: 7, Run: "r1", Dialog: true}); err != nil {
		t.Fatal(err)
	}
	if err := cl.PromptHint(ctx, PromptHintMsg{Row: 8, Run: "r1"}); err == nil {
		t.Fatal("PromptHint unknown session: want an error")
	}
	if err := cl.Forget(ctx, 7, "r1"); err == nil {
		t.Fatal("Forget running: want an error")
	}

	if already, err := cl.Stop(ctx, StopReq{Row: 7, Run: "r1", Launch: info.Launch}); err != nil || already {
		t.Fatalf("Stop = %v, %v, want a stop under way", already, err)
	}
	var exit ExitMsg
	if err := json.Unmarshal(pane.expect(Exit), &exit); err != nil {
		t.Fatal(err)
	}
	if !exit.Requested {
		t.Fatalf("exit = %+v, want requested", exit)
	}
	got, err := cl.List(ctx)
	if err != nil || len(got) != 1 || !got[0].Exited {
		t.Fatalf("list = %+v, %v", got, err)
	}
	if already, err := cl.Stop(ctx, StopReq{Row: 7, Run: "r1", Launch: info.Launch}); err != nil || !already {
		t.Fatalf("Stop of an exited run = %v, %v, want already exited", already, err)
	}
	if err := cl.Forget(ctx, 7, "r1"); err != nil {
		t.Fatal(err)
	}
	if already, err := cl.Stop(ctx, StopReq{Row: 7, Run: "r1", Launch: info.Launch}); err == nil || already {
		t.Fatalf("Stop after forget = %v, %v, want no session", already, err)
	}
	if got, err := cl.List(ctx); err != nil || len(got) != 0 {
		t.Fatalf("list after forget = %+v, %v", got, err)
	}
}

func TestClientCancelClosesTheConnection(t *testing.T) {
	path := startServer(t, Options{})
	cl, err := Dial(ctxT(t), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cl.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := cl.List(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("List with a cancelled ctx = %v", err)
	}
}

func TestEnsureNeverReplacesAV1Host(t *testing.T) {
	path := fakeV1Host(t)
	marker := filepath.Join(t.TempDir(), "started")
	exe := filepath.Join(t.TempDir(), "fake-watchtower")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := Ensure(ctxT(t), path, exe); !errors.Is(err, ErrHostV1) {
		t.Fatalf("Ensure over a v1 host = %v, want ErrHostV1", err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("Ensure started a host beside a v1 host")
	}
}

func TestEnsureStartsAHostWhenNoneAnswers(t *testing.T) {
	path := socketPath(t)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(asHostEnv, "1")
	started := SetTestLauncher(t)
	ctx := ctxT(t)
	if err := Ensure(ctx, path, exe); err != nil {
		t.Fatal(err)
	}
	cl, err := Dial(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	pid := cl.Pid()
	_ = cl.Close()
	if pids := started(); len(pids) != 1 || pids[0] != pid {
		t.Fatalf("started %v, want the one host %d", pids, pid)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("started host not alive: %v", err)
	}
	// A second Ensure finds it answering and starts nothing.
	if err := Ensure(ctx, path, "/nonexistent/watchtower"); err != nil {
		t.Fatalf("Ensure with a live v2 host = %v", err)
	}
	if pids := started(); len(pids) != 1 {
		t.Fatalf("a second Ensure started a host: %v", pids)
	}
}

// A cancel while the request is in flight (the host never answers) ends the
// call with ctx.Err() and closes the connection, which the host sees.
func TestClientCancelMidCallClosesTheConnection(t *testing.T) {
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	gotRequest := make(chan struct{})
	hostSawClose := make(chan struct{})
	go func() {
		nc, err := l.Accept()
		if err != nil {
			return
		}
		defer func() { _ = nc.Close() }()
		if _, _, err := ReadFrame(nc); err != nil { // Hello
			return
		}
		_ = WriteFrame(nc, HelloOK, encode(HelloMsg{Version: ProtocolVersion, Pid: 1}))
		if _, _, err := ReadFrame(nc); err != nil { // the List, never answered
			return
		}
		close(gotRequest)
		_ = nc.SetReadDeadline(time.Now().Add(ioTimeout))
		if _, _, err := ReadFrame(nc); err != nil && !errors.Is(err, os.ErrDeadlineExceeded) {
			close(hostSawClose)
		}
	}()

	cl, err := Dial(ctxT(t), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cl.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-gotRequest
		cancel()
	}()
	if _, err := cl.List(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("List cancelled mid-call = %v, want context.Canceled", err)
	}
	select {
	case <-hostSawClose:
	case <-time.After(ioTimeout):
		t.Fatal("the host never saw the connection close")
	}
	if _, err := cl.List(ctxT(t)); err == nil {
		t.Fatal("a call after a mid-call cancel succeeded on an out-of-step connection")
	}
}
