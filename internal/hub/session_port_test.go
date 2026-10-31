package hub

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
)

// testSessionHost is an in-process session-host on a short socket; every
// hosted process group is killed and reaped before it stops.
func testSessionHost(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "hsh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "h.sock")
	l, err := sessionhost.Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = sessionhost.NewServer(sessionhost.Options{}).Serve(ctx, l)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	t.Cleanup(func() {
		c, err := sessionhost.Dial(context.Background(), socket)
		if err != nil {
			return
		}
		defer func() { _ = c.Close() }()
		list, _ := c.List(context.Background())
		for _, info := range list {
			if info.Pid > 0 && !info.Exited {
				_ = syscall.Kill(-info.Pid, syscall.SIGKILL)
				for deadline := time.Now().Add(5 * time.Second); syscall.Kill(info.Pid, 0) == nil && time.Now().Before(deadline); {
					time.Sleep(10 * time.Millisecond)
				}
			}
		}
	})
	return socket
}

// The runtime's session port is the real one (Task 15): with a host socket
// and no Options.Sessions, a phone's session_stop becomes the host's Stop
// request for the workspace's own run, which ends and is forgotten.
func TestTheRuntimeStopsASessionThroughTheRealPort(t *testing.T) {
	d, project := fileDB(t)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
VALUES (?, 'claude', 'Session', '/tmp/hubtest-acme', '00000000-0000-4000-8000-000000000001')`, project)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := res.LastInsertId()
	socket := testSessionHost(t)
	path, err := mainFile(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	host, err := sessionhost.Dial(context.Background(), socket)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = host.Close() }()
	if _, err := host.Launch(context.Background(), sessionhost.LaunchReq{Row: session, Run: "r1", Executable: "/bin/sh",
		Args: []string{"-c", "exec sleep 30"}, Cwd: os.TempDir(), Cols: 80, Rows: 24, Scope: sessionhost.Scope(path)}); err != nil {
		t.Fatal(err)
	}
	e := runEndToEnd(t, "", func(o *Options) {
		o.DB = d
		o.SessionStart = sessionstart.Deps{Socket: socket, CLIPath: "/usr/bin/false"}
	})
	a := e.phone.NewAction("session_stop")
	id := strconv.FormatInt(session, 10)
	a.EntityID = &id
	seq, err := e.phone.Queue(a)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.phone.Send(seq); err != nil {
		t.Fatal(err)
	}
	eventually(t, 15*time.Second, "session_stop applied", func() bool {
		if _, err := e.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return e.phone.Echoes[seq].Status == wire.StatusApplied
	})
	list, err := host.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, info := range list {
		if info.Row == session {
			t.Fatalf("the stopped run is still listed: %+v", info)
		}
	}
}
