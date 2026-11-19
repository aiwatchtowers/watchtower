//go:build darwin && cgo

package ownerconfirm

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

// execPeerEnv turns the test binary into a peer that connects to the socket
// the variable names, says "x", waits for one byte, and execs a shell that
// keeps the connection, says "y" and sleeps: the process at the end of the
// socket is then other code than the one that connected.
const execPeerEnv = "WATCHTOWER_OWNERCONFIRM_EXEC_PEER"

func TestMain(m *testing.M) {
	if path := os.Getenv(execPeerEnv); path != "" {
		runExecPeer(path)
		return
	}
	os.Exit(m.Run())
}

func runExecPeer(path string) {
	c, err := net.Dial("unix", path) //nolint:gosec // G704: the test's own socket path
	if err != nil {
		os.Exit(2)
	}
	f, err := c.(*net.UnixConn).File()
	if err != nil {
		os.Exit(3)
	}
	if _, err := f.Write([]byte("x")); err != nil {
		os.Exit(4)
	}
	if _, err := f.Read(make([]byte, 1)); err != nil {
		os.Exit(5)
	}
	if err := unix.Dup2(int(f.Fd()), 3); err != nil {
		os.Exit(6)
	}
	_ = syscall.Exec("/bin/sh", []string{"sh", "-c", "printf y >&3; exec sleep 600"}, os.Environ())
	os.Exit(7)
}

// accepted is the server end of a real unix connection from this process.
func accepted(t *testing.T) net.Conn {
	t.Helper()
	dir, err := os.MkdirTemp("", "oct")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "s.sock"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = l.Close() })
	c, err := net.Dial("unix", l.Addr().String())
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })
	s, err := l.Accept()
	require.NoError(t, err)
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// The audit token names this (ad-hoc signed) test binary: a requirement it
// meets passes, one it does not is refused — the release CLI's and the
// app's included (another identifier, a team).
func TestCheckTokenByRequirement(t *testing.T) {
	tok, err := ReadPeerToken(accepted(t))
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), tok.PID())
	require.NoError(t, checkToken(tok, "always"))
	assert.Error(t, checkToken(tok, "never"))
	assert.Error(t, checkToken(tok, cliRequirement("ABCDE12345")))
	assert.Error(t, checkToken(tok, appRequirement("")))
	assert.Error(t, checkToken(tok, "not a requirement ((("))
}

// A development CLI is its own CLI peer (same executable), never the app,
// even with the development override.
func TestVerifyPeersFromADevelopmentBuild(t *testing.T) {
	tok, err := ReadPeerToken(accepted(t))
	require.NoError(t, err)
	require.NoError(t, VerifySameTeamCLI(context.Background(), tok))
	t.Setenv(DevTrustUnsignedEnv, "")
	assert.ErrorIs(t, VerifyDesktopPeer(context.Background(), tok), ErrDevBuild)
	t.Setenv(DevTrustUnsignedEnv, "1")
	assert.ErrorIs(t, VerifyDesktopPeer(context.Background(), tok), ErrNotDesktop)
}

// The exec race (D17): the token read when the peer connected no longer
// names any running code once the peer exec'd, so the check refuses it,
// whatever it exec'd.
func TestCheckTokenRefusesAPeerThatExecd(t *testing.T) {
	dir, err := os.MkdirTemp("", "oce")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "s.sock"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = l.Close() })

	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), execPeerEnv+"="+l.Addr().String())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	require.NoError(t, cmd.Start())
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
	})
	s, err := l.Accept()
	require.NoError(t, err)
	t.Cleanup(func() { _ = s.Close() })
	read := func() string {
		b := make([]byte, 1)
		_, err := s.Read(b)
		require.NoError(t, err)
		return string(b)
	}
	require.Equal(t, "x", read())
	tok, err := ReadPeerToken(s) // before the exec: the peer waits for our byte
	require.NoError(t, err)
	require.NoError(t, checkToken(tok, "always"), "the connecting image")
	_, err = s.Write([]byte("g"))
	require.NoError(t, err)
	require.Equal(t, "y", read(), "the peer exec'd")
	assert.Error(t, checkToken(tok, "always"), "a token of the exec'd image still matched")
	_, err = tokenPath(tok)
	assert.Error(t, err)
	now, err := ReadPeerToken(s)
	require.NoError(t, err)
	assert.Equal(t, tok.PID(), now.PID(), "the same process")
	assert.NotEqual(t, tok, now, "another image")
}
