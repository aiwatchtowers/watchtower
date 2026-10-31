package sessionhost

import (
	"encoding/json"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestHelloAcceptsV1AndV2AnswersV2(t *testing.T) {
	path := startServer(t, Options{})
	for _, v := range []int{1, 2} {
		c := dialRaw(t, path)
		c.send(Hello, HelloMsg{Version: v})
		ft, p := c.read()
		if ft != HelloOK {
			t.Fatalf("hello v%d reply = %#x (%s), want HelloOK", v, ft, p)
		}
		var h HelloMsg
		if err := json.Unmarshal(p, &h); err != nil {
			t.Fatal(err)
		}
		if h.Version != 2 || h.Pid != os.Getpid() {
			t.Fatalf("hello v%d answer = %+v, want version 2 and our pid", v, h)
		}
	}
}

// expectNoError sends a List and fails when an Error arrives before Listed.
func (c *client) expectNoError() {
	c.t.Helper()
	c.send(List, nil)
	for {
		ft, p := c.read()
		if ft == Listed {
			return
		}
		if ft == Error {
			c.t.Fatalf("unexpected error: %s", errMsg(c.t, p))
		}
	}
}

func TestInputToNeverAttaches(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	info := a.launch(1, `exec cat`)
	if info.Launch != 1 {
		t.Fatalf("launch counter = %d, want 1", info.Launch)
	}

	b := dial(t, path)
	b.send(InputTo, InputToReq{Row: 1, Run: "r1", Launch: info.Launch, Data: []byte("from-b\n")})
	b.expectNoError()
	a.outputUntil(func(s string) bool { return strings.Contains(s, "from-b") })

	// b is still bound to nothing: a v1 Input is refused there.
	b.send(Input, []byte("x"))
	if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, "not attached") {
		t.Fatalf("b input = %q, want not attached", msg)
	}
	// a keeps its binding: its own Input still echoes, and it was never
	// told it was taken over.
	a.send(Input, []byte("from-a\n"))
	a.outputUntil(func(s string) bool { return strings.Contains(s, "from-a") })
}

func TestInputToWrongRunOrLaunchIsRefused(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	info := a.launch(1, `exec cat`)
	b := dial(t, path)
	cases := []struct {
		req  InputToReq
		want string
	}{
		{InputToReq{Row: 1, Run: "r2", Launch: info.Launch, Data: []byte("x")}, "no session"},
		{InputToReq{Row: 1, Run: "r1", Launch: info.Launch + 1, Data: []byte("x")}, "launch"},
		{InputToReq{Row: 1, Run: "r1", Launch: 0, Data: []byte("x")}, "launch"},
		{InputToReq{Row: 2, Run: "r1", Launch: info.Launch, Data: []byte("x")}, "no session"},
	}
	for _, tc := range cases {
		b.send(InputTo, tc.req)
		if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, tc.want) {
			t.Fatalf("input_to %+v = %q, want %q", tc.req, msg, tc.want)
		}
	}

	c := dial(t, path)
	ended := c.launch(3, `exit 0`)
	c.expect(Exit)
	b.send(InputTo, InputToReq{Row: 3, Run: "r1", Launch: ended.Launch, Data: []byte("x")})
	if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, "not running") {
		t.Fatalf("input_to exited = %q, want not running", msg)
	}
}

func TestListIsNonAttaching(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	info := a.launch(1, `exec cat`)
	b := dial(t, path)
	if got := b.list(); len(got) != 1 || got[0].Launch != info.Launch {
		t.Fatalf("list = %+v", got)
	}
	b.send(Input, []byte("x"))
	if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, "not attached") {
		t.Fatalf("b input after list = %q, want not attached", msg)
	}
	a.send(Input, []byte("still-a\n"))
	a.outputUntil(func(s string) bool { return strings.Contains(s, "still-a") })
}

func TestLaunchCounterSurvivesClientReconnect(t *testing.T) {
	path := startServer(t, Options{})
	c1 := dial(t, path)
	first := c1.launch(1, `exit 0`)
	c1.expect(Exit)
	_ = c1.nc.Close()

	c2 := dial(t, path)
	c2.send(Forget, AttachReq{Row: 1, Run: "r1"})
	c2.expect(Forgot)
	c2.send(Launch, LaunchReq{
		Row: 1, Run: "r2", Executable: "/bin/sh", Args: []string{"-c", "exit 0"},
		Cwd: os.TempDir(), Cols: 80, Rows: 24, Agent: "claude", Detach: true,
	})
	var second SessionInfo
	if err := json.Unmarshal(c2.expect(Launched), &second); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reap(t, second.Pid) })
	if first.Launch != 1 || second.Launch != 2 {
		t.Fatalf("launch counters = %d, %d, want 1, 2", first.Launch, second.Launch)
	}
	if second.Agent != "claude" {
		t.Fatalf("agent = %q, want claude", second.Agent)
	}
	other := c2.launch(2, `exit 0`) // a detached launch left c2 unbound
	if other.Launch != 1 {
		t.Fatalf("row 2 launch counter = %d, want 1", other.Launch)
	}
}

func TestRequestedStopExitCarriesRequested(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	// The shell and its sleeps ignore SIGHUP, so only the SIGKILL after
	// stopGrace ends them; a.launch's cleanup reaps the group either way.
	info := a.launch(1, `trap '' HUP; echo ready; while :; do sleep 0.1; done`)
	a.outputUntil(func(s string) bool { return strings.Contains(s, "ready") })

	b := dial(t, path)
	start := time.Now()
	b.send(Stop, StopReq{Row: 1, Run: "r1", Launch: info.Launch})
	b.expect(Stopping)

	_ = a.nc.SetReadDeadline(time.Now().Add(stopGrace + ioTimeout))
	var exit ExitMsg
	for {
		ft, p, err := ReadFrame(a.nc)
		if err != nil {
			t.Fatalf("read exit: %v", err)
		}
		if ft == Exit {
			if err := json.Unmarshal(p, &exit); err != nil {
				t.Fatal(err)
			}
			break
		}
	}
	if elapsed := time.Since(start); elapsed < stopGrace-500*time.Millisecond {
		t.Fatalf("exit after %v, want the SIGKILL after about %v", elapsed, stopGrace)
	}
	if !exit.Requested || exit.Code != nil {
		t.Fatalf("exit = %+v, want requested with a signal (nil) code", exit)
	}
	got := b.list()
	if len(got) != 1 || !got[0].Exited {
		t.Fatalf("list = %+v, want one exited session", got)
	}
	// A re-attach replays the exit with requested too.
	c := dial(t, path)
	c.send(Attach, AttachReq{Row: 1, Run: "r1"})
	c.expect(Attached)
	var replayed ExitMsg
	if err := json.Unmarshal(c.expect(Exit), &replayed); err != nil {
		t.Fatal(err)
	}
	if !replayed.Requested {
		t.Fatalf("replayed exit = %+v, want requested", replayed)
	}
}

func TestStopWrongLaunchIsRefused(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	info := a.launch(1, `sleep 30`)
	b := dial(t, path)
	b.send(Stop, StopReq{Row: 1, Run: "r1", Launch: info.Launch + 1})
	if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, "launch") {
		t.Fatalf("stop wrong launch = %q", msg)
	}
	if got := b.list(); len(got) != 1 || got[0].Exited {
		t.Fatalf("list = %+v, want the session still running", got)
	}
}

func TestNaturalExitHasNoRequested(t *testing.T) {
	path := startServer(t, Options{})
	a := dial(t, path)
	a.launch(1, `exit 3`)
	p := a.expect(Exit)
	var raw map[string]any
	if err := json.Unmarshal(p, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["requested"]; ok {
		t.Fatalf("natural exit = %s, want no requested key", p)
	}
	if code, _ := raw["code"].(float64); code != 3 {
		t.Fatalf("natural exit = %s, want code 3", p)
	}
}

func TestHelloBelowMinimumVersionCloses(t *testing.T) {
	path := startServer(t, Options{})
	c := dialRaw(t, path)
	c.send(Hello, HelloMsg{Version: 0})
	if ft, _ := c.read(); ft != Error {
		t.Fatalf("hello v0 reply = %#x, want Error", ft)
	}
	if _, _, err := c.readErr(); err == nil {
		t.Fatal("connection still open after a v0 hello")
	}
}

// readExit reads frames on c until an Exit and decodes it.
func (c *client) readExit(within time.Duration) (ExitMsg, []byte) {
	c.t.Helper()
	_ = c.nc.SetReadDeadline(time.Now().Add(within))
	for {
		ft, p, err := ReadFrame(c.nc)
		if err != nil {
			c.t.Fatalf("read exit: %v", err)
		}
		if ft == Exit {
			var m ExitMsg
			if err := json.Unmarshal(p, &m); err != nil {
				c.t.Fatal(err)
			}
			return m, p
		}
	}
}

func (c *client) stopping() StoppingMsg {
	c.t.Helper()
	var m StoppingMsg
	if err := json.Unmarshal(c.expect(Stopping), &m); err != nil {
		c.t.Fatal(err)
	}
	return m
}

// A Stop that lands after the child was reaped but before its exit is
// recorded (the output drain) finds the exit natural: Stopping says
// already_exited and the Exit has no requested. The afterReap hook holds
// the window open until the Stop was answered.
func TestStopDuringDrainKeepsTheExitNatural(t *testing.T) {
	reaped := make(chan struct{})
	release := make(chan struct{})
	path := startServer(t, Options{afterReap: func() {
		close(reaped)
		<-release
	}})
	a := dial(t, path)
	// The background sleep ignores SIGHUP and keeps the process group
	// alive, so a SIGHUP in the window would be delivered (and wrongly
	// mark the run); a.launch's cleanup kills the group.
	info := a.launch(1, `trap '' HUP; sleep 30 & exit 0`)
	select {
	case <-reaped:
	case <-time.After(ioTimeout):
		t.Fatal("child not reaped")
	}

	b := dial(t, path)
	b.send(Stop, StopReq{Row: 1, Run: "r1", Launch: info.Launch})
	m := b.stopping()
	close(release)
	if !m.AlreadyExited {
		t.Fatalf("stopping = %+v, want already_exited", m)
	}
	exit, raw := a.readExit(ioTimeout)
	if exit.Requested {
		t.Fatalf("exit = %s, want a natural exit", raw)
	}
	// After the Exit, a Stop still says the run had exited.
	b.send(Stop, StopReq{Row: 1, Run: "r1", Launch: info.Launch})
	if m := b.stopping(); !m.AlreadyExited {
		t.Fatalf("stopping after exit = %+v, want already_exited", m)
	}
}

// A SIGHUP that cannot be delivered is an Error and leaves the run
// unmarked: its later exit is natural.
func TestStopSignalFailureLeavesRequestedUnset(t *testing.T) {
	path := startServer(t, Options{signalGroup: func(int, syscall.Signal) error { return syscall.EPERM }})
	a := dial(t, path)
	info := a.launch(1, `echo ready; sleep 30`)
	a.outputUntil(func(s string) bool { return strings.Contains(s, "ready") })

	b := dial(t, path)
	b.send(Stop, StopReq{Row: 1, Run: "r1", Launch: info.Launch})
	if msg := errMsg(t, b.expect(Error)); !strings.Contains(msg, "signal group") {
		t.Fatalf("stop with EPERM = %q", msg)
	}
	if err := syscall.Kill(-info.Pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	if exit, raw := a.readExit(ioTimeout); exit.Requested {
		t.Fatalf("exit = %s, want no requested after a failed stop", raw)
	}
}
