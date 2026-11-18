package chatengine

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat/listenstub"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// liveRig runs engines whose sessions are real processes: this test binary
// re-exec'd as the listenstub `ai session --listen` stand-in, detached in
// its own session. Every group it spawned is killed and waited for in
// Cleanup.
type liveRig struct {
	t    *testing.T
	d    *db.DB
	ws   string
	cfg  Config
	ends chan turnEnd

	mu    sync.Mutex
	pgids []int
	argvs [][]string
}

// shortDir is a short folder: a socket path has at most 103 bytes.
func shortDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "wtc")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	return d
}

func newLiveRig(t *testing.T) *liveRig {
	t.Helper()
	t.Setenv(listenstub.Env, "1")
	exe, err := os.Executable()
	require.NoError(t, err)
	ws := shortDir(t)
	g := &liveRig{t: t, d: openDB(t), ws: ws, ends: make(chan turnEnd, 16)}
	g.cfg = Config{Exe: exe, Dir: filepath.Join(ws, "chatengine"), DB: g.d, Workspace: ws, TempDir: shortDir(t)}
	t.Cleanup(func() {
		g.mu.Lock()
		pgids := append([]int(nil), g.pgids...)
		g.mu.Unlock()
		for _, sg := range sessionGroups(filepath.Join(g.cfg.Dir, "sessions"), psArgs) {
			pgids = append(pgids, sg.pgid)
		}
		for _, pg := range pgids {
			_ = syscall.Kill(-pg, syscall.SIGKILL)
		}
		for _, pg := range pgids {
			if !groupGoneSoon(pg) {
				t.Errorf("session group %d outlived the test", pg)
			}
		}
	})
	return g
}

// engine starts an engine (reattaching to what is running); Cleanup
// detaches it before the groups are killed.
func (g *liveRig) engine() *Engine {
	g.t.Helper()
	e := New(g.cfg)
	inner := e.c.Start
	e.c.Start = func(argv []string) (Process, error) {
		p, err := inner(argv)
		if err == nil {
			g.mu.Lock()
			g.pgids = append(g.pgids, p.PGID())
			g.argvs = append(g.argvs, argv)
			g.mu.Unlock()
		}
		return p, err
	}
	e.OnTurnEnd(func(conv int64, turnID, status string) { g.ends <- turnEnd{conv, turnID, status} })
	g.t.Cleanup(func() { _ = e.Detach(context.Background()) })
	require.NoError(g.t, e.Start(context.Background()))
	return e
}

func (g *liveRig) pgid(i int) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.pgids[i]
}

// fifo makes a FIFO the stub's turn reads its script from; withAck also
// makes <fifo>.ack.
func (g *liveRig) fifo(name string, withAck bool) string {
	g.t.Helper()
	p := filepath.Join(g.ws, name)
	require.NoError(g.t, syscall.Mkfifo(p, 0o600))
	if withAck {
		require.NoError(g.t, syscall.Mkfifo(p+".ack", 0o600))
	}
	return p
}

// script opens the FIFO for writing: it returns once the stub's turn runs
// and opened it.
func script(t *testing.T, fifo string) *os.File {
	t.Helper()
	w, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	require.NoError(t, err)
	t.Cleanup(func() { _ = w.Close() })
	return w
}

func say(t *testing.T, w *os.File, lines ...string) {
	t.Helper()
	for _, l := range lines {
		_, err := fmt.Fprintln(w, l)
		require.NoError(t, err)
	}
}

// awaitAck waits for the stub's ack: everything scripted before it was
// emitted by the session.
func awaitAck(t *testing.T, fifo string) {
	t.Helper()
	f, err := os.Open(fifo + ".ack")
	require.NoError(t, err)
	defer func() { _ = f.Close() }()
	_, err = bufio.NewReader(f).ReadString('\n')
	require.NoError(t, err)
}

func (g *liveRig) turn(e *Engine, conv int64, text string) chatstore.Started {
	g.t.Helper()
	st, err := e.Turn(context.Background(), turnReq(conv, text, ""))
	require.NoError(g.t, err)
	return st
}

func alive(pgid int) bool { return !errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH) }

// TestChatengine_RestartMidTurnReattachesAndFinishes: engine A starts a
// turn and detaches (a daemon restart) while it streams; the session runs
// on, engine B reattaches, the replay and the live rest end the reply
// `complete` with the whole text, and B closes the session once idle.
func TestChatengine_RestartMidTurnReattachesAndFinishes(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	conv := newConversation(t, g.d)
	fifo := g.fifo("f", false)
	st := g.turn(a, conv, "fifo:"+fifo)
	w := script(t, fifo)
	say(t, w, "text hello ")
	require.NoError(t, a.Detach(context.Background()))
	pg := g.pgid(0)
	assert.True(t, alive(pg), "the session outlives the engine")
	require.NotNil(t, lease(t, g.d, conv), "the turn keeps its lease")

	say(t, w, "text world")
	g.engine()
	say(t, w, "done")
	assert.Equal(t, turnEnd{conv, st.TurnID, chatstore.StatusComplete}, <-g.ends)
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, chatstore.StatusComplete, r.status)
	assert.Equal(t, "partial answer hello world", r.text)
	assert.False(t, r.errorCode.Valid)
	assert.Nil(t, lease(t, g.d, conv))
	assert.True(t, groupGoneSoon(pg), "the reattached session is closed once idle")
}

// TestChatengine_TurnEndedWhileDetachedIsWrittenOnAttach: the turn ends
// while no engine is attached; the next engine's attach writes its end.
func TestChatengine_TurnEndedWhileDetachedIsWrittenOnAttach(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	conv := newConversation(t, g.d)
	fifo := g.fifo("f", true)
	st := g.turn(a, conv, "fifo:"+fifo)
	w := script(t, fifo)
	require.NoError(t, a.Detach(context.Background()))
	say(t, w, "step s1", "text the end", "done")
	awaitAck(t, fifo) // turn_done went out with no engine attached

	g.engine()
	assert.Equal(t, turnEnd{conv, st.TurnID, chatstore.StatusComplete}, <-g.ends)
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, chatstore.StatusComplete, r.status)
	assert.Equal(t, "partial answer the end", r.text)
	var steps int
	require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_turn_steps WHERE message_id = ? AND ok = 1`,
		st.AssistantMessageID).Scan(&steps))
	assert.Equal(t, 1, steps)
}

// TestChatengine_ReplayPastCapStoresWholeText: 700 KB streamed while
// detached (past the session's 600 KB turn buffer) still lands whole.
func TestChatengine_ReplayPastCapStoresWholeText(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	conv := newConversation(t, g.d)
	fifo := g.fifo("f", true)
	st := g.turn(a, conv, "fifo:"+fifo)
	w := script(t, fifo)
	require.NoError(t, a.Detach(context.Background()))
	say(t, w, "text big:700000", "ack")
	awaitAck(t, fifo)

	g.engine()
	say(t, w, "done")
	awaitAck(t, fifo)
	assert.Equal(t, chatstore.StatusComplete, (<-g.ends).status)
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, "partial answer "+strings.Repeat("y", 700000), r.text)
}

// TestChatengine_KilledMidTurnSweepsSessionLost: the engine and the session
// both die mid-turn; the next engine finds no live socket, marks the reply
// session_lost, releases the lease and removes the stale socket and group
// files.
func TestChatengine_KilledMidTurnSweepsSessionLost(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	conv := newConversation(t, g.d)
	fifo := g.fifo("f", true)
	st := g.turn(a, conv, "fifo:"+fifo)
	w := script(t, fifo)
	say(t, w, "text hello", "ack")
	awaitAck(t, fifo)
	require.NoError(t, a.Detach(context.Background())) // the engine is gone
	pg := g.pgid(0)
	require.NoError(t, syscall.Kill(-pg, syscall.SIGKILL)) // and so is the session
	require.True(t, groupGoneSoon(pg))
	sock := SessionSocketPath(g.ws, g.cfg.TempDir, conv)
	_, err := os.Stat(sock)
	require.NoError(t, err, "a killed session leaves its socket file")

	g.engine()
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, chatstore.StatusPartial, r.status)
	assert.Equal(t, "session_lost", r.errorCode.String)
	assert.Nil(t, lease(t, g.d, conv))
	_, err = os.Stat(sock)
	assert.True(t, os.IsNotExist(err), "the stale socket is removed")
	_, err = os.Stat(filepath.Join(g.cfg.Dir, "sessions", strconv.FormatInt(conv, 10)+".pgid"))
	assert.True(t, os.IsNotExist(err), "the dead group's file is removed")
}

// TestChatShutdownCLI_ReapsWithoutEngine: with no engine running, the CLI
// fallback cancels and closes every session over its socket and reaps its
// group; the next engine marks the cut replies session_lost.
func TestChatShutdownCLI_ReapsWithoutEngine(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	var started []chatstore.Started
	for i := range 2 {
		conv := newConversation(t, g.d)
		fifo := g.fifo("f"+strconv.Itoa(i), false)
		started = append(started, g.turn(a, conv, "fifo:"+fifo))
		script(t, fifo) // its turn runs
	}
	require.NoError(t, a.Detach(context.Background()))
	require.True(t, alive(g.pgid(0)) && alive(g.pgid(1)))

	require.NoError(t, ShutdownSessions(context.Background(), g.ws, g.cfg.TempDir))
	for i := range 2 {
		assert.False(t, alive(g.pgid(i)), "session %d reaped", i)
	}
	assert.Empty(t, listSessionSockets(g.ws, g.cfg.TempDir))
	files, _ := filepath.Glob(filepath.Join(g.cfg.Dir, "sessions", "*.pgid"))
	assert.Empty(t, files)

	g.engine()
	for _, st := range started {
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Equal(t, "session_lost", r.errorCode.String)
		assert.Nil(t, lease(t, g.d, st.ConversationID))
	}
}

// TestChat04_ListenTurnContentOnlyOnSocket: a detached session's argv
// carries flags and its socket path only; the owner's text reaches it over
// the 0600 session socket (BEHAVIOR CHAT-04 — see docs/inventory/chat.md).
func TestChat04_ListenTurnContentOnlyOnSocket(t *testing.T) {
	g := newLiveRig(t)
	a := g.engine()
	conv := newConversation(t, g.d)
	st := g.turn(a, conv, "SECRET-T10A-TEXT")
	assert.Equal(t, chatstore.StatusComplete, (<-g.ends).status)
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, "echo: SECRET-T10A-TEXT", r.text, "the text arrived on the socket")

	g.mu.Lock()
	argv := strings.Join(g.argvs[0], " ")
	g.mu.Unlock()
	assert.Contains(t, argv, "--listen "+SessionSocketPath(g.ws, g.cfg.TempDir, conv))
	assert.NotContains(t, argv, "SECRET")
	live, err := psArgs(g.pgid(0)) // the running process's own command line
	require.NoError(t, err)
	assert.Contains(t, live, "--listen")
	assert.NotContains(t, live, "SECRET")
	info, err := os.Stat(SessionSocketPath(g.ws, g.cfg.TempDir, conv))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	dir, err := os.Stat(filepath.Dir(SessionSocketPath(g.ws, g.cfg.TempDir, conv)))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), dir.Mode().Perm())
}

// TestChatengine_DetachWhileBindingKeepsTheTurn: the engine goes away while
// a new turn's session is still starting (before it bound its socket); the
// session is left running, and the next engine adopts it once it listens,
// sends it the turn and finishes it (D23: a restart never cuts a turn).
func TestChatengine_DetachWhileBindingKeepsTheTurn(t *testing.T) {
	g := newLiveRig(t)
	gate := filepath.Join(g.ws, "gate")
	require.NoError(t, syscall.Mkfifo(gate, 0o600))
	t.Setenv(listenstub.GateEnv, gate)
	a := g.engine()
	conv := newConversation(t, g.d)
	fifo := g.fifo("f", false)
	st := g.turn(a, conv, "fifo:"+fifo)
	release := script(t, gate) // the session runs, held before it binds
	require.NoError(t, a.Detach(context.Background()))
	require.NotNil(t, lease(t, g.d, conv))

	g.engine()
	say(t, release, "bind")
	w := script(t, fifo) // the turn reached the session
	say(t, w, "text resent", "done")
	assert.Equal(t, turnEnd{conv, st.TurnID, chatstore.StatusComplete}, <-g.ends)
	r, _ := readRow(t, g.d, st.AssistantMessageID)
	assert.Equal(t, chatstore.StatusComplete, r.status)
	assert.Equal(t, "partial answer resent", r.text)
}
