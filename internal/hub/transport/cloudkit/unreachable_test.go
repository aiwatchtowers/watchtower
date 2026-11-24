package cloudkit

import (
	"context"
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"watchtower/internal/hub/transport"
)

// ErrBridgeNotListening stands only for a bridge not serving its socket yet
// (no socket file, or the connection refused), which the hub keeps quiet
// about while the bridge starts (#2192); every other failure to reach the
// socket is plain ErrUnavailable, which it logs.

func TestNoSocketFileIsNotListening(t *testing.T) {
	err := checkSocket(filepath.Join(t.TempDir(), SocketName))
	if !errors.Is(err, ErrBridgeNotListening) {
		t.Fatalf("missing socket: %v", err)
	}
}

func TestARefusedConnectionIsNotListening(t *testing.T) {
	dir, err := os.MkdirTemp("", "ck") // short: a socket path has a length cap
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, SocketName)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	l.SetUnlinkOnClose(false)
	_ = l.Close() // the file stays, nothing accepts on it
	var d net.Dialer
	_, err = d.DialContext(context.Background(), "unix", path)
	if err == nil {
		t.Fatal("dialed a socket nobody listens on")
	}
	if got := unreachable(err); !errors.Is(got, ErrBridgeNotListening) {
		t.Fatalf("refused (%v): %v", err, got)
	}
}

func TestOtherSocketFailuresAreUnavailableOnly(t *testing.T) {
	for _, err := range []error{
		&fs.PathError{Op: "lstat", Path: "bridge.sock", Err: syscall.EACCES},
		&net.OpError{Op: "dial", Net: "unix", Err: &os.SyscallError{Syscall: "connect", Err: syscall.EACCES}},
		&net.OpError{Op: "dial", Net: "unix", Err: os.ErrDeadlineExceeded},
		context.DeadlineExceeded,
	} {
		got := unreachable(err)
		if errors.Is(got, ErrBridgeNotListening) || !errors.Is(got, transport.ErrUnavailable) {
			t.Errorf("%v: %v", err, got)
		}
	}
}
