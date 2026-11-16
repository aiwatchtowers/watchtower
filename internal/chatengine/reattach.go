package chatengine

// Turns outlive the daemon (unified chat spec §7, D23): the engine starts
// each `ai session` detached (its own session, setsid) with `--listen
// <session socket>` and talks protocol v2 over that socket. Detach leaves
// the processes running; the next engine's Start reattaches to every live
// session socket, sends `attach`, and folds the replayed turn through the
// normal Turn.Apply (text set whole, steps upserted by id, artifacts by key
// and message), then streams on.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/platform"
)

// Session socket numbers: how long a spawned session may take to bind its
// socket (it opens the database and builds its backend first), the retry
// step while it binds, and the bound on one dial with its greeting.
const (
	bindTimeout = 30 * time.Second
	bindRetry   = 50 * time.Millisecond
	dialBudget  = 5 * time.Second
)

// listening: sessions run on session sockets (Config.Workspace set).
func (e *Engine) listening() bool { return e.c.Workspace != "" }

func (e *Engine) tempDir() string {
	if e.c.TempDir != "" {
		return e.c.TempDir
	}
	return os.TempDir()
}

// sessionSocket is conv's session socket.
func (e *Engine) sessionSocket(conv int64) string {
	return SessionSocketPath(e.c.Workspace, e.tempDir(), conv)
}

// sessionSocketDirs are the folders session sockets live in: the
// workspace's, and the temp fallback's (the rule is decided per path, so a
// workspace may use both).
func sessionSocketDirs(workspaceDir, tempDir string) []string {
	return []string{
		filepath.Join(workspaceDir, "chatengine", "sessions"),
		filepath.Join(fallbackDir(workspaceDir, tempDir), "sessions"),
	}
}

// listSessionSockets is every <conv>.sock in the session socket folders.
func listSessionSockets(workspaceDir, tempDir string) map[int64]string {
	out := map[int64]string{}
	for _, dir := range sessionSocketDirs(workspaceDir, tempDir) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, de := range entries {
			name := de.Name()
			conv, err := strconv.ParseInt(strings.TrimSuffix(name, ".sock"), 10, 64)
			if !strings.HasSuffix(name, ".sock") || err != nil || conv <= 0 {
				continue
			}
			out[conv] = filepath.Join(dir, name)
		}
	}
	return out
}

// reattach dials every session socket and adopts each live session; a
// socket nobody serves any more is removed. It returns the adopted
// conversations (the sweep leaves their groups and leases alone).
func (e *Engine) reattach(ctx context.Context) map[int64]bool {
	adopted := map[int64]bool{}
	if !e.listening() {
		return adopted
	}
	for conv, path := range listSessionSockets(e.c.Workspace, e.tempDir()) {
		p, err := e.c.dialSession(ctx, path)
		if err != nil {
			if errors.Is(err, errStaleSocket) {
				_ = os.Remove(path)
			}
			continue
		}
		e.adopt(conv, p)
		adopted[conv] = true
	}
	if n := len(adopted); n > 0 {
		log.Printf("chatengine: %d chat sessions of an earlier run reattached", n)
	}
	return adopted
}

// adopt takes a running session over: its turn, when the engine's lease
// still holds one, is replayed and runs on; it is never reused for another
// turn (its config is not known), so it closes once idle.
func (e *Engine) adopt(conv int64, p Process) {
	held, err := e.heldTurnOf(conv)
	if err != nil {
		log.Printf("chatengine: conversation %d: reading its running turn failed (%s)", conv, errClass(err))
	}
	s := &session{r: e, conv: conv, kick: make(chan struct{}, 1), lastActivity: e.c.Clock(),
		phase: phaseLive, retire: true, turn: held, proc: p, adopted: true}
	e.mu.Lock()
	e.sessions = append(e.sessions, s)
	e.wg.Add(1)
	e.mu.Unlock()
	s.poke()
	go s.loop()
}

// heldTurnOf is conv's turn the engine's lease holds (nil = none).
func (e *Engine) heldTurnOf(conv int64) (*heldTurn, error) {
	l, err := e.c.DB.GetChatLease(conv)
	if err != nil || l == nil || l.Owner != db.ChatLeaseHub || l.OwnerID != LeaseOwnerID {
		return nil, err
	}
	st := chatstore.Started{ConversationID: conv, TurnID: l.TurnID}
	var parent, project sql.NullInt64
	err = e.c.DB.QueryRow(`SELECT m.id, m.parent_id, c.project_id FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE m.conversation_id = ? AND m.turn_id = ? AND m.role = 'assistant' ORDER BY m.id DESC LIMIT 1`,
		conv, l.TurnID).Scan(&st.AssistantMessageID, &parent, &project)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("chatengine: reading a running turn: %w", err)
	}
	st.UserMessageID = parent.Int64
	if project.Valid {
		st.ProjectID = &project.Int64
	}
	// A zero start time heartbeats the lease on the first tick.
	return &heldTurn{st: st, t: e.store.Turn(st)}, nil
}

// errStaleSocket: nothing serves the socket file any more.
var errStaleSocket = errors.New("chatengine: stale session socket")

// dialSessionSocket connects to a session socket and reads its greeting.
// The peer must be this user's process; its pid (the leader of its own
// session and group, setsid) is what the process is signalled by.
func dialSessionSocket(ctx context.Context, path string) (Process, error) {
	conn, pid, err := connectSession(ctx, path)
	if err != nil {
		return nil, err
	}
	return newSockProcess(conn, pid), nil
}

// connectSession dials path within dialBudget and reads the greeting.
func connectSession(ctx context.Context, path string) (net.Conn, int, error) {
	ctx, cancel := context.WithTimeout(ctx, dialBudget)
	defer cancel()
	var d net.Dialer
	c, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ENOENT) {
			return nil, 0, fmt.Errorf("%w: %w", errStaleSocket, err)
		}
		return nil, 0, fmt.Errorf("chatengine: dialing a session: %w", err)
	}
	uc, ok := c.(*net.UnixConn)
	if !ok {
		_ = c.Close()
		return nil, 0, errors.New("chatengine: not a unix connection")
	}
	uid, err := platform.PeerUID(uc)
	if err != nil || uid != os.Getuid() {
		_ = c.Close()
		return nil, 0, errors.New("chatengine: a session socket of another user")
	}
	pid, err := platform.PeerPID(uc)
	if err != nil || pid <= 1 {
		_ = c.Close()
		return nil, 0, errors.New("chatengine: the session's pid is unknown")
	}
	stop := context.AfterFunc(ctx, func() { _ = c.Close() })
	line, err := readLineRaw(c)
	stop()
	var g chat.Event
	if err != nil || json.Unmarshal(line, &g) != nil || g.Type != chat.EventListenReady {
		_ = c.Close()
		return nil, 0, errors.New("chatengine: the session did not greet")
	}
	return c, pid, nil
}

// readLineRaw reads one line a byte at a time, so nothing after it is
// buffered away from the event reader.
func readLineRaw(r io.Reader) ([]byte, error) {
	var line []byte
	b := make([]byte, 1)
	for len(line) < 4096 {
		if _, err := io.ReadFull(r, b); err != nil {
			return nil, err //nolint:wrapcheck // the caller refuses the session either way
		}
		if b[0] == '\n' {
			return line, nil
		}
		line = append(line, b[0])
	}
	return nil, errors.New("chatengine: greeting too long")
}

// listenStart spawns `<exe> argv...` (argv carries --listen <socket>) in its
// own session and process group, with no stdio (the daemon may exit long
// before it), and connects to its socket once it bound it.
func (e *Engine) listenStart(argv []string) (Process, error) {
	path := flagValue(argv, "--listen")
	if e.c.Exe == "" || path == "" {
		return nil, errors.New("chatengine: no watchtower executable or session socket")
	}
	cmd := exec.Command(e.c.Exe, argv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err //nolint:wrapcheck // classified by the caller's log
	}
	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	pid := cmd.Process.Pid
	conn, err := e.dialSpawned(path, exited)
	if err != nil {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		<-exited
		return nil, err
	}
	return newSockProcess(conn, pid), nil
}

// dialSpawned waits for a spawned session to bind its socket: it retries
// while the socket is not there or refuses, until the process exited, the
// engine stops, or bindTimeout passed.
func (e *Engine) dialSpawned(path string, exited <-chan struct{}) (net.Conn, error) {
	deadline := time.NewTimer(bindTimeout)
	defer deadline.Stop()
	for {
		conn, _, err := connectSession(e.stopCtx, path)
		if err == nil {
			return conn, nil
		}
		if !errors.Is(err, errStaleSocket) {
			return nil, err
		}
		retry := time.NewTimer(bindRetry)
		select {
		case <-retry.C:
		case <-exited:
			retry.Stop()
			return nil, errors.New("chatengine: the session exited before it listened")
		case <-e.stopCtx.Done():
			retry.Stop()
			return nil, ErrClosed
		case <-deadline.C:
			retry.Stop()
			return nil, errors.New("chatengine: the session did not listen in time")
		}
	}
}

// flagValue is argv's value of flag ("" = absent).
func flagValue(argv []string, flag string) string {
	for i, a := range argv {
		if a == flag && i+1 < len(argv) {
			return argv[i+1]
		}
	}
	return ""
}

// sockProcess is a session on its socket. It is gone for the engine once
// the socket ends (the process exits, or another client took it over).
type sockProcess struct {
	conn   net.Conn
	pid    int
	exited chan struct{}
	once   sync.Once
}

func newSockProcess(conn net.Conn, pid int) *sockProcess {
	return &sockProcess{conn: conn, pid: pid, exited: make(chan struct{})}
}

func (p *sockProcess) gone()                   { p.once.Do(func() { close(p.exited) }) }
func (p *sockProcess) Stdin() io.Writer        { return p.conn }
func (p *sockProcess) Stdout() io.ReadCloser   { return sockOut{p} }
func (p *sockProcess) PGID() int               { return p.pid }
func (p *sockProcess) Terminate() error        { return syscall.Kill(p.pid, syscall.SIGTERM) }
func (p *sockProcess) Kill() error             { return syscall.Kill(-p.pid, syscall.SIGKILL) }
func (p *sockProcess) Exited() <-chan struct{} { return p.exited }

// Detach drops the connection and leaves the process running.
func (p *sockProcess) Detach() { _ = p.conn.Close() }

type sockOut struct{ p *sockProcess }

func (o sockOut) Read(b []byte) (int, error) {
	n, err := o.p.conn.Read(b)
	if err != nil {
		o.p.gone()
	}
	return n, err //nolint:wrapcheck // the event reader ends on any error
}

func (o sockOut) Close() error { return o.p.conn.Close() } //nolint:wrapcheck // closing only
