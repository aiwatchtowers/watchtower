package ownerconfirm

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// shortSocket is a socket path under the 104-byte sun_path limit (t.TempDir
// on macOS is too long for one).
func shortSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "oc")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, FileName)
}

// serveOnce answers one request with reply ("" never answers) and hands the
// request it read to got.
func serveOnce(t *testing.T, path, reply string, got chan<- Request) {
	t.Helper()
	l, err := net.Listen("unix", path)
	require.NoError(t, err)
	done := make(chan struct{})
	t.Cleanup(func() { _ = l.Close(); <-done })
	go func() {
		defer close(done)
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer func() { _ = c.Close() }()
		line, err := bufio.NewReader(c).ReadBytes('\n')
		if err != nil {
			return
		}
		var req Request
		_ = json.Unmarshal(line, &req)
		got <- req
		if reply != "" {
			_, _ = c.Write([]byte(reply + "\n"))
			return
		}
		_, _ = c.Read(make([]byte, 1)) // until the caller hangs up
	}()
}

// trustPeer stands in for the signature check, recording the pid it saw.
func trustPeer(t *testing.T, verdict error) *int {
	t.Helper()
	orig := VerifyPeer
	t.Cleanup(func() { VerifyPeer = orig })
	seen := new(int)
	VerifyPeer = func(_ context.Context, pid int) error {
		*seen = pid
		return verdict
	}
	return seen
}

func TestSocketPathSitsNextToTheDatabase(t *testing.T) {
	assert.Equal(t, filepath.Join("/w", "ws", FileName), SocketPath(filepath.Join("/w", "ws", "watchtower.db")))
}

func TestAskSendsTheRequestAndReadsTheDecision(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the peer pid is read on macOS only")
	}
	path := shortSocket(t)
	got := make(chan Request, 1)
	serveOnce(t, path, `{"decision":"confirmed"}`, got)
	seen := trustPeer(t, nil)

	rep, err := Ask(context.Background(), path,
		Request{Verb: "approve an action", Args: []string{"actions", "approve", "5"}})
	require.NoError(t, err)
	assert.Equal(t, Confirmed, rep.Decision)
	req := <-got
	assert.Equal(t, Version, req.V)
	assert.Equal(t, []string{"actions", "approve", "5"}, req.Args)
	assert.Equal(t, os.Getpid(), *seen, "the peer is the listening process")
}

// A listener that is not the signed Watchtower app never sees the request,
// and its "confirmed" is never read.
func TestAskRefusesAPeerThatFailsTheSignatureCheck(t *testing.T) {
	path := shortSocket(t)
	got := make(chan Request, 1)
	serveOnce(t, path, `{"decision":"confirmed"}`, got)
	trustPeer(t, errors.New("not signed"))

	_, err := Ask(context.Background(), path, Request{Verb: "x", Args: []string{"actions", "approve", "5"}})
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrUntrustedPeer), "%v", err)
	select {
	case <-got:
		t.Fatal("the request reached an untrusted listener")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestAskWithoutADesktopIsErrNoDesktop(t *testing.T) {
	_, err := Ask(context.Background(), shortSocket(t), Request{Verb: "x"})
	assert.True(t, errors.Is(err, ErrNoDesktop), "%v", err)
}

func TestAskGivesUpAtTheDeadline(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the peer pid is read on macOS only")
	}
	path := shortSocket(t)
	serveOnce(t, path, "", make(chan Request, 1))
	trustPeer(t, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_, err := Ask(ctx, path, Request{Verb: "x"})
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrNoDesktop))
	assert.Contains(t, err.Error(), "in time")
}

// A development CLI (go test's binary is ad-hoc signed, no Team ID) refuses
// every Desktop unless the development override is set.
func TestVerifyDesktopRefusesFromADevelopmentBuild(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("codesign is macOS only")
	}
	t.Setenv(DevTrustUnsignedEnv, "")
	err := VerifyDesktop(context.Background(), os.Getpid())
	require.ErrorIs(t, err, ErrDevBuild)
	t.Setenv(DevTrustUnsignedEnv, "1")
	assert.NoError(t, VerifyDesktop(context.Background(), os.Getpid()))
}

func TestVerifyDesktopFailsClosedWithoutCodesign(t *testing.T) {
	orig := codesignPath
	t.Cleanup(func() { codesignPath = orig })
	codesignPath = "/nonexistent/codesign"
	assert.Error(t, VerifyDesktop(context.Background(), os.Getpid()))
}
