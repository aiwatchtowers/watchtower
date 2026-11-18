//go:build darwin || linux

package platform

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// shortDir is a temp folder short enough for a socket path on darwin.
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "wtp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// dialPair is both ends of one unix connection.
func dialPair(t *testing.T) (client, server *net.UnixConn) {
	t.Helper()
	l, err := ListenLocked(filepath.Join(shortDir(t), "p.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	c, err := net.Dial("unix", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	s, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return c.(*net.UnixConn), s.(*net.UnixConn)
}

// Both ends see this process: its uid and its pid.
func TestPeerUIDAndPID(t *testing.T) {
	c, s := dialPair(t)
	for _, conn := range []*net.UnixConn{c, s} {
		uid, err := PeerUID(conn)
		if err != nil || uid != os.Getuid() {
			t.Errorf("PeerUID = %d, %v; want %d", uid, err, os.Getuid())
		}
		pid, err := PeerPID(conn)
		if err != nil || pid != os.Getpid() {
			t.Errorf("PeerPID = %d, %v; want %d", pid, err, os.Getpid())
		}
	}
}

// One listener per path: a second is ErrSocketBusy; the socket is 0600;
// after the first closes, a stale socket file is replaced.
func TestListenLockedOneListener(t *testing.T) {
	path := filepath.Join(shortDir(t), "x.sock")
	l, err := ListenLocked(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("socket mode = %v, %v; want 0600", fi.Mode().Perm(), err)
	}
	if _, err := ListenLocked(path); !errors.Is(err, ErrSocketBusy) {
		t.Errorf("second ListenLocked = %v, want ErrSocketBusy", err)
	}
	_ = l.Close()
	// A crash leaves the socket file behind: the next listener replaces it.
	ul, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	ul.SetUnlinkOnClose(false)
	_ = ul.Close()
	l2, err := ListenLocked(path)
	if err != nil {
		t.Fatalf("over a stale socket: %v", err)
	}
	_ = l2.Close()
}

// A file that is not a socket is never removed.
func TestListenLockedRefusesAFile(t *testing.T) {
	path := filepath.Join(shortDir(t), "f.sock")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ListenLocked(path); err == nil {
		t.Fatal("ListenLocked over a regular file succeeded")
	}
	if b, err := os.ReadFile(path); err != nil || string(b) != "x" {
		t.Errorf("the file changed: %q, %v", b, err)
	}
}
