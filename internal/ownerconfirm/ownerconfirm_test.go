package ownerconfirm

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
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

func TestSocketPathSitsNextToTheDatabase(t *testing.T) {
	assert.Equal(t, filepath.Join("/w", "ws", FileName), SocketPath(filepath.Join("/w", "ws", "watchtower.db")))
}

func TestAskSendsTheRequestAndReadsTheDecision(t *testing.T) {
	path := shortSocket(t)
	got := make(chan Request, 1)
	serveOnce(t, path, `{"decision":"confirmed"}`, got)

	rep, err := Ask(context.Background(), path,
		Request{Verb: "approve an action", Args: []string{"actions", "approve", "5"}, Agent: "CLAUDECODE"})
	require.NoError(t, err)
	assert.Equal(t, Confirmed, rep.Decision)
	req := <-got
	assert.Equal(t, Version, req.V)
	assert.Equal(t, []string{"actions", "approve", "5"}, req.Args)
	assert.Equal(t, "CLAUDECODE", req.Agent)
}

func TestAskWithoutADesktopIsErrNoDesktop(t *testing.T) {
	_, err := Ask(context.Background(), shortSocket(t), Request{Verb: "x"})
	assert.True(t, errors.Is(err, ErrNoDesktop), "%v", err)
}

func TestAskGivesUpAtTheDeadline(t *testing.T) {
	path := shortSocket(t)
	serveOnce(t, path, "", make(chan Request, 1))
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_, err := Ask(ctx, path, Request{Verb: "x"})
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrNoDesktop))
	assert.Contains(t, err.Error(), "in time")
}
