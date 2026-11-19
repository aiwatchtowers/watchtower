package chat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"watchtower/internal/ownerconfirm"
	"watchtower/internal/platform"
)

// ListenIdleTTL is how long a session with no engine attached and no turn
// running waits before it exits (CHAT-03's idle TTL).
const ListenIdleTTL = 10 * time.Minute

// verifyBudget bounds one client's signature check.
const verifyBudget = 5 * time.Second

// ListenOptions configure ServeListen.
type ListenOptions struct {
	// Path is the session socket (<workspace>/chatengine/sessions/<conv>.sock
	// or its temp fallback): 0600 in a 0700 folder.
	Path string
	// Verify checks the client by its token, read when it connected (nil =
	// on macOS ownerconfirm.VerifySameTeamCLI — the engine is this team's
	// watchtower CLI, unified chat spec §7, D17 —; elsewhere the client runs
	// this session's own executable).
	Verify func(ctx context.Context, t ownerconfirm.PeerToken) error
	// Clock reads the time for the idle TTL (nil = time.Now).
	Clock func() time.Time
	// IdleTTL is the idle exit (0 = ListenIdleTTL).
	IdleTTL time.Duration

	// Test seams: the listener (nil = bound at Path), the client's token
	// read at accept and whether it already sent bytes.
	listener net.Listener
	peer     func(net.Conn) (ownerconfirm.PeerToken, error)
	pending  func(net.Conn) (int, error)
}

// ServeListen runs s with its transport on a unix socket instead of stdio
// (`ai session --listen`, unified chat spec §7): the session outlives the
// engine that started it. One client at a time — a newer verified client
// replaces the older; a client sends {"type":"attach"} and gets the current
// turn's events replayed from its start, the attached line, then every event
// live; its other commands are protocol v2's. With no client and no turn
// running the session exits after IdleTTL; a turn keeps running without a
// client. It returns when s.Run returns (close, ctx, idle exit); when Run
// failed (its backend did not start) with no client to see the error, the
// error is first handed to the next client to attach within IdleTTL.
func ServeListen(ctx context.Context, o ListenOptions, s *Session) error {
	if o.Verify == nil {
		o.Verify = defaultListenVerify
	}
	if o.Clock == nil {
		o.Clock = time.Now
	}
	if o.IdleTTL <= 0 {
		o.IdleTTL = ListenIdleTTL
	}
	if o.peer == nil {
		o.peer = socketPeer
	}
	if o.pending == nil {
		o.pending = platform.Pending
	}
	l := o.listener
	if l == nil {
		var err error
		if l, err = listenSession(o.Path); err != nil {
			return err
		}
	}
	srv := &listenServer{o: o, s: s, l: l, accepted: make(chan net.Conn), gone: make(chan net.Conn),
		attached: make(chan net.Conn), done: make(chan struct{})}
	return srv.serve(ctx)
}

// listenSession binds the session socket: its folder made 0700, the socket
// 0600, one listener per path.
func listenSession(path string) (net.Listener, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("session socket folder: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, fmt.Errorf("session socket folder: %w", err)
	}
	l, err := platform.ListenLocked(path)
	if err != nil {
		return nil, fmt.Errorf("session socket: %w", err)
	}
	return l, nil
}

// socketPeer is the client's audit token, read now; a client of another
// user is refused here.
func socketPeer(c net.Conn) (ownerconfirm.PeerToken, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return ownerconfirm.PeerToken{}, errors.New("not a unix connection")
	}
	uid, err := platform.PeerUID(uc)
	if err != nil {
		return ownerconfirm.PeerToken{}, err //nolint:wrapcheck // the client is refused either way
	}
	if uid != os.Getuid() {
		return ownerconfirm.PeerToken{}, errors.New("another user's process")
	}
	return ownerconfirm.ReadPeerToken(uc) //nolint:wrapcheck // as above
}

type listenServer struct {
	o ListenOptions
	s *Session
	l net.Listener

	accepted chan net.Conn // verified and greeted
	gone     chan net.Conn // a client's reader ended
	attached chan net.Conn // a client's attach was replayed
	done     chan struct{} // serve returned

	cmdMu sync.Mutex // one command line at a time into Run
}

func (srv *listenServer) serve(ctx context.Context) error {
	defer close(srv.done)
	defer func() { _ = srv.l.Close() }()
	srv.s.w.listen()
	cmdR, cmdW := io.Pipe()
	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	runDone := make(chan error, 1)
	go func() { runDone <- srv.s.Run(runCtx, cmdR) }()
	go srv.acceptLoop(ctx)

	var (
		cur       net.Conn
		running   = true
		idleExit  bool
		runErr    error
		idleSince time.Time
	)
	closeCur := func() {
		if cur != nil {
			// Close first: an Emit blocked writing to a client that stopped
			// reading holds the writer's lock until its write fails.
			_ = cur.Close()
			srv.s.w.detach(cur)
			cur = nil
		}
	}
	defer closeCur()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case c := <-srv.accepted:
			closeCur()
			cur = c
			go srv.readClient(c, cmdW)
		case c := <-srv.gone:
			if c == cur {
				closeCur()
			} else {
				_ = c.Close()
			}
		case c := <-srv.attached:
			if !running && c == cur {
				return runErr // the start failure was handed over
			}
		case runErr = <-runDone:
			running = false
			_ = cmdW.Close()
			// Only a failed start waits to hand its error over; a close,
			// ctx or idle exit ends the session now.
			if runErr == nil || idleExit || !srv.s.w.pending() {
				return runErr
			}
		case <-tick.C:
			idle := cur == nil && (!running || !srv.s.busy())
			if !idle {
				idleSince = time.Time{}
				continue
			}
			now := srv.o.Clock()
			if idleSince.IsZero() {
				idleSince = now
			}
			if now.Sub(idleSince) < srv.o.IdleTTL {
				continue
			}
			if !running {
				return runErr // nobody came for the rest
			}
			idleExit = true
			_ = cmdW.Close() // stdin EOF: Run returns
		}
	}
}

// acceptLoop accepts clients until the listener closes: each one's token is
// read at once, it is checked, and only when it sent nothing yet is it
// greeted and handed to serve.
func (srv *listenServer) acceptLoop(ctx context.Context) {
	for {
		c, err := srv.l.Accept()
		if err != nil {
			return
		}
		if !srv.admit(ctx, c) {
			_ = c.Close()
			continue
		}
		select {
		case srv.accepted <- c:
		case <-srv.done:
			_ = c.Close()
			return
		}
	}
}

// admit checks a new client (FILES-01: nothing of it is logged).
func (srv *listenServer) admit(ctx context.Context, c net.Conn) bool {
	t, err := srv.o.peer(c)
	if err != nil {
		return false
	}
	vctx, cancel := context.WithTimeout(ctx, verifyBudget)
	err = srv.o.Verify(vctx, t)
	cancel()
	if err != nil {
		return false
	}
	// A client writes only after the greeting: bytes already waiting may
	// come from a process that exec'd since it connected.
	if n, err := srv.o.pending(c); err != nil || n > 0 {
		return false
	}
	b, err := encodeEvent(Event{Type: EventListenReady})
	if err != nil {
		return false
	}
	_, err = c.Write(b)
	return err == nil
}

// readClient forwards c's commands into Run; attach is answered here.
func (srv *listenServer) readClient(c net.Conn, cmdW io.Writer) {
	defer func() {
		select {
		case srv.gone <- c:
		case <-srv.done:
		}
	}()
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 64<<10), maxCommandBytes)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var cmd struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(line, &cmd) == nil && cmd.Type == CommandAttach {
			if srv.s.w.attach(c) != nil {
				return
			}
			select {
			case srv.attached <- c:
			case <-srv.done:
				return
			}
			continue
		}
		srv.cmdMu.Lock()
		_, err := cmdW.Write(append(append([]byte(nil), line...), '\n'))
		srv.cmdMu.Unlock()
		if err != nil {
			return // Run ended
		}
	}
}
