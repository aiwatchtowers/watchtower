package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat/listenstub"
	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
)

// orderLog records the owner stop's steps in order.
type orderLog struct {
	mu    sync.Mutex
	steps []string
}

func (o *orderLog) add(s string) {
	o.mu.Lock()
	o.steps = append(o.steps, s)
	o.mu.Unlock()
}

func (o *orderLog) get() []string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]string(nil), o.steps...)
}

// shortSocketTempDir points TMPDIR (os.TempDir, the socket fallback's root) at a
// short folder: a socket path has at most 103 bytes.
func shortSocketTempDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "wts")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	t.Setenv("TMPDIR", d)
	return d
}

// fakeChatSock serves chat.sock for cfg's workspace like the engine's
// server does for a CLI peer: the greeting, then ok for every request; each
// op is recorded.
func fakeChatSock(t *testing.T, cfg *config.Config, order *orderLog) {
	t.Helper()
	path := chatengine.SocketPath(cfg.WorkspaceDir(), os.TempDir())
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	l, err := net.Listen("unix", path)
	require.NoError(t, err)
	var wg sync.WaitGroup
	t.Cleanup(func() { _ = l.Close(); wg.Wait() })
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { _ = c.Close() }()
				_, _ = io.WriteString(c, `{"event":"ready","protocol":1}`+"\n")
				sc := bufio.NewScanner(c)
				for sc.Scan() {
					var req struct {
						ID string `json:"id"`
						Op string `json:"op"`
					}
					if json.Unmarshal(sc.Bytes(), &req) != nil {
						return
					}
					if req.Op != "hello" {
						order.add(req.Op)
					}
					_, _ = fmt.Fprintf(c, `{"id":%q,"ok":true,"result":{}}`+"\n", req.ID)
				}
			}()
		}
	}()
}

// recordStopOrder adds the stop's SIGTERM and marker write to order.
func recordStopOrder(t *testing.T, order *orderLog) {
	t.Helper()
	prevKill, prevMarker := syncStopKill, writeStoppedMarker
	t.Cleanup(func() { syncStopKill, writeStoppedMarker = prevKill, prevMarker })
	syncStopKill = func(pid int, sig syscall.Signal) error {
		order.add(sig.String())
		return prevKill(pid, sig)
	}
	writeStoppedMarker = func(ws string, at time.Time, by string) error {
		order.add("marker")
		return prevMarker(ws, at, by)
	}
}

// TestSyncStop_InternalFlagRegistered: `sync stop --internal` exists.
func TestSyncStop_InternalFlagRegistered(t *testing.T) {
	f := syncStopCmd.Flags().Lookup("internal")
	require.NotNil(t, f)
	assert.Equal(t, "false", f.DefValue)
}

// TestSyncStop_WritesStoppedMarker: the owner's stop writes
// <workspace>/daemon.stopped (0600, by "cli") once the daemon is gone.
func TestSyncStop_WritesStoppedMarker(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)
	shortSocketTempDir(t)
	helper := startDelayedHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	recordStop(t, helper)

	captureStdout(t, func() { require.NoError(t, runSyncStop(cfg, false)) })
	m, ok, err := daemon.ReadStoppedMarker(cfg.WorkspaceDir())
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, "cli", m.By)
	info, err := os.Stat(filepath.Join(cfg.WorkspaceDir(), daemon.StoppedMarkerName))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}

// TestSyncStop_InternalWritesNoMarker: the app's own stop leaves no marker.
func TestSyncStop_InternalWritesNoMarker(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)
	shortSocketTempDir(t)
	helper := startDelayedHelper(t)
	writeFakePIDFile(t, pidPath, helper.pid())
	recordStop(t, helper)

	captureStdout(t, func() { require.NoError(t, runSyncStopOpts(cfg, false, true)) })
	_, ok, err := daemon.ReadStoppedMarker(cfg.WorkspaceDir())
	require.NoError(t, err)
	assert.False(t, ok)
}

// TestSyncStop_OwnerPathOrder: the owner's stop asks chat.sock for
// chat_shutdown, then sends SIGTERM, then writes the marker; with chat.sock
// unreachable it reaps the sessions directly before the SIGTERM.
func TestSyncStop_OwnerPathOrder(t *testing.T) {
	t.Run("chat.sock answers", func(t *testing.T) {
		cfg, pidPath := syncStopTestConfig(t)
		shortSocketTempDir(t)
		order := &orderLog{}
		fakeChatSock(t, cfg, order)
		helper := startDelayedHelper(t)
		writeFakePIDFile(t, pidPath, helper.pid())
		recordStop(t, helper)
		recordStopOrder(t, order)
		prev := shutdownChatSessions
		t.Cleanup(func() { shutdownChatSessions = prev })
		shutdownChatSessions = func(context.Context, string, string) error {
			order.add("shutdown_sessions")
			return nil
		}

		captureStdout(t, func() { require.NoError(t, runSyncStop(cfg, false)) })
		assert.Equal(t, []string{"chat_shutdown", "terminated", "marker"}, order.get())
	})
	t.Run("chat.sock unreachable", func(t *testing.T) {
		cfg, pidPath := syncStopTestConfig(t)
		shortSocketTempDir(t)
		order := &orderLog{}
		helper := startDelayedHelper(t)
		writeFakePIDFile(t, pidPath, helper.pid())
		recordStop(t, helper)
		recordStopOrder(t, order)
		prev := shutdownChatSessions
		t.Cleanup(func() { shutdownChatSessions = prev })
		shutdownChatSessions = func(ctx context.Context, ws, tmp string) error {
			order.add("shutdown_sessions")
			return prev(ctx, ws, tmp)
		}

		captureStdout(t, func() { require.NoError(t, runSyncStop(cfg, false)) })
		assert.Equal(t, []string{"shutdown_sessions", "terminated", "marker"}, order.get())
	})
}

// TestSyncStop_InternalLeavesSessionsRunning: the app's restart (`sync stop
// --internal`) sends no chat_shutdown and writes no marker; a chat turn's
// detached session keeps running, and the next engine reattaches to it and
// finishes the turn.
func TestSyncStop_InternalLeavesSessionsRunning(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)
	tmp := shortSocketTempDir(t)
	// The fake daemon starts before the stub's env is set (it would run
	// the stub too).
	helper := startDelayedHelper(t)
	t.Setenv(listenstub.Env, "1")
	ws := cfg.WorkspaceDir()
	require.NoError(t, os.MkdirAll(ws, 0o700))
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)

	ends := make(chan string, 4)
	newEngine := func() *chatengine.Engine {
		e := chatengine.New(chatengine.Config{Exe: os.Args[0], Dir: filepath.Join(ws, "chatengine"), DB: d,
			Workspace: ws, TempDir: tmp})
		e.OnTurnEnd(func(_ int64, _, status string) { ends <- status })
		t.Cleanup(func() { _ = e.Detach(context.Background()) })
		require.NoError(t, e.Start(context.Background()))
		return e
	}
	a := newEngine()
	fifo := filepath.Join(tmp, "f")
	require.NoError(t, syscall.Mkfifo(fifo, 0o600))
	st, err := a.Turn(context.Background(), chatengine.TurnRequest{StartRequest: chatstore.StartRequest{
		ConversationID: conv, Mode: chatstore.ModeSend, Text: "fifo:" + fifo}})
	require.NoError(t, err)
	w, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	require.NoError(t, err)
	t.Cleanup(func() { _ = w.Close() })
	b, err := os.ReadFile(filepath.Join(ws, "chatengine", "sessions", strconv.FormatInt(conv, 10)+".pgid"))
	require.NoError(t, err)
	pgid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		for range 250 { // reaped by init: wait until the group is gone
			if errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH) {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Errorf("session group %d outlived the test", pgid)
	})
	require.NoError(t, a.Detach(context.Background())) // the daemon's stop

	order := &orderLog{}
	fakeChatSock(t, cfg, order)
	writeFakePIDFile(t, pidPath, helper.pid())
	recordStop(t, helper)
	captureStdout(t, func() { require.NoError(t, runSyncStopOpts(cfg, false, true)) })

	assert.Empty(t, order.get(), "no chat_shutdown")
	_, marked, err := daemon.ReadStoppedMarker(ws)
	require.NoError(t, err)
	assert.False(t, marked)
	assert.False(t, errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH), "the session runs on")

	newEngine() // the next daemon
	_, err = fmt.Fprintln(w, "done")
	require.NoError(t, err)
	assert.Equal(t, chatstore.StatusComplete, <-ends)
	var status, text string
	require.NoError(t, d.QueryRow(`SELECT status, text FROM chat_messages WHERE id = ?`, st.AssistantMessageID).
		Scan(&status, &text))
	assert.Equal(t, chatstore.StatusComplete, status)
	assert.Equal(t, "partial answer ", text)
}

// TestSyncDaemon_StartRemovesStoppedMarker: a daemon start removes the
// owner's stopped marker before it serves chat.sock.
func TestSyncDaemon_StartRemovesStoppedMarker(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default", false)
	require.NoError(t, err)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	require.NoError(t, daemon.WriteStoppedMarker(cfg.WorkspaceDir(), time.Now(), "cli"))

	origChat, origHub := startChatEngineFn, startGoHubFn
	t.Cleanup(func() { startChatEngineFn, startGoHubFn = origChat, origHub })
	markedAtChat := true
	startChatEngineFn = func(context.Context, *config.Config, *log.Logger) (*chatengine.Engine, func()) {
		_, markedAtChat, _ = daemon.ReadStoppedMarker(cfg.WorkspaceDir())
		return nil, func() {}
	}
	startGoHubFn = func(context.Context, *config.Config, *db.DB, *chatengine.Engine, *log.Logger) func() {
		return func() {}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	require.NoError(t, runSyncDaemon(ctx, cfg, database, log.New(io.Discard, "", 0), nil))
	assert.False(t, markedAtChat, "removed before chat.sock is served")
	_, ok, err := daemon.ReadStoppedMarker(cfg.WorkspaceDir())
	require.NoError(t, err)
	assert.False(t, ok)
}

// TestChatShutdown_ReportsSurvivingSessions: when the engine does not
// answer and the direct reap leaves a session running, the chat shutdown
// fails (`watchtower chat shutdown` exits non-zero).
func TestChatShutdown_ReportsSurvivingSessions(t *testing.T) {
	cfg, _ := syncStopTestConfig(t)
	shortSocketTempDir(t)
	prevReq, prevReap := requestChatShutdown, shutdownChatSessions
	t.Cleanup(func() { requestChatShutdown, shutdownChatSessions = prevReq, prevReap })
	requestChatShutdown = func(context.Context, string) error { return errors.New("no engine") }
	var budget time.Duration
	shutdownChatSessions = func(ctx context.Context, _, _ string) error {
		dl, _ := ctx.Deadline()
		budget = time.Until(dl)
		return errors.New("1 chat session is still running")
	}
	require.Error(t, shutdownChat(cfg))
	assert.Greater(t, budget, chatShutdownBudget-time.Second, "the direct reap gets its own budget")
}

// TestChatShutdown_SocketTimeoutBoundsTheSocketStep: the app's fallback
// (`chat shutdown --socket-timeout 1s`, it has asked the engine itself)
// waits on chat.sock only that long, and the direct reap still runs on its
// own budget — inside the app's 12 s watchdog.
func TestChatShutdown_SocketTimeoutBoundsTheSocketStep(t *testing.T) {
	cfg, _ := syncStopTestConfig(t)
	shortSocketTempDir(t)
	prevReq, prevReap := requestChatShutdown, shutdownChatSessions
	t.Cleanup(func() { requestChatShutdown, shutdownChatSessions = prevReq, prevReap })
	var socketBudget time.Duration
	requestChatShutdown = func(ctx context.Context, _ string) error {
		dl, _ := ctx.Deadline()
		socketBudget = time.Until(dl)
		return errors.New("no answer")
	}
	reaped := false
	shutdownChatSessions = func(context.Context, string, string) error {
		reaped = true
		return nil
	}
	require.NoError(t, shutdownChatWithin(cfg, time.Second))
	assert.LessOrEqual(t, socketBudget, time.Second)
	assert.True(t, reaped, "the direct reap runs after the short socket step")

	flag := chatShutdownCmd.Flags().Lookup("socket-timeout")
	require.NotNil(t, flag, "the app passes --socket-timeout")
	assert.Equal(t, chatShutdownBudget.String(), flag.DefValue)
}
