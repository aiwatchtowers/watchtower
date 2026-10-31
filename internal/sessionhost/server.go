package sessionhost

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/signal"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// DiscardHangup catches SIGHUP and drops it, so the host survives the hangup
// of the terminal or session it was started from. It must not ignore SIGHUP
// instead: an ignored signal stays ignored across exec, so every hosted child
// would survive the SIGHUP that stops it and the PTY hangup. A caught signal
// is reset to its default action in an exec'd child. stop undoes it.
func DiscardHangup() (stop func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGHUP)
	return func() { signal.Stop(ch) }
}

// ErrHostRunning is returned by Listen when a live host already owns the
// socket path.
var ErrHostRunning = errors.New("sessionhost: a host is already running on this socket")

// outQueue is how many frames may wait for a slow client before the host
// drops the connection rather than stall the PTY reader.
const outQueue = 256

// helloTimeout bounds how long a fresh connection may take to say Hello.
const helloTimeout = 10 * time.Second

// defaultRingSize is used when Options.RingSize is not set.
const defaultRingSize = 2 << 20

// TakenOver is the Error message a connection gets just before the host
// closes it because a newer attach took its session over. The app matches
// it by value (HostedTerminalSession) and does not reattach.
const TakenOver = "taken over"

// finishTimeout bounds how long a taken-over connection may take to read
// its last frame before the host closes it anyway.
const finishTimeout = 2 * time.Second

// Options configures a Server.
type Options struct {
	// IdleExit ends Serve once no session is held and no connection is
	// bound to one for this long; zero or less disables it. A connection
	// bound to nothing (the app's control connection) does not keep the
	// host alive, so a newer host binary takes over once it is idle.
	IdleExit time.Duration
	// RingSize is the per-session output tail kept for a re-attach.
	RingSize int
	// Now is the clock for session start times.
	Now func() time.Time
	// signalGroup replaces Stop's process-group signal (tests only).
	signalGroup func(pgid int, sig syscall.Signal) error
	// afterReap runs once a child is reaped, before its output drains and
	// its exit is recorded (tests only: holds the drain window open).
	afterReap func()
}

// Server owns hosted sessions and serves clients over a listener.
type Server struct {
	opts Options

	mu       sync.Mutex
	sessions map[sessionKey]*session
	launches map[int64]uint64 // per-row launch counter; never reset
	conns    map[*conn]struct{}
	closed   bool

	changed chan struct{} // nudges the idle check; capacity 1
}

// NewServer returns a server with no sessions.
func NewServer(opts Options) *Server {
	if opts.RingSize <= 0 {
		opts.RingSize = defaultRingSize
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	return &Server{
		opts:     opts,
		sessions: map[sessionKey]*session{},
		launches: map[int64]uint64{},
		conns:    map[*conn]struct{}{},
		changed:  make(chan struct{}, 1),
	}
}

// Listen binds the host socket. A live host on the path gives ErrHostRunning;
// a stale socket file is removed and re-bound. The socket is mode 0600. A
// lock file beside the socket (path + ".lock") is held while the listener is
// open, so two hosts starting at once never unlink each other's socket.
func Listen(socketPath string) (net.Listener, error) {
	lock, err := os.OpenFile(socketPath+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open host lock: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lock.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrHostRunning
		}
		return nil, fmt.Errorf("lock host: %w", err)
	}
	if c, err := net.DialTimeout("unix", socketPath, time.Second); err == nil { //nolint:gosec // G704: a local unix socket path the owner chose (--socket or WATCHTOWER_SESSION_HOST_SOCKET), not a network URL
		_ = c.Close()
		_ = lock.Close()
		return nil, ErrHostRunning
	}
	if fi, err := os.Lstat(socketPath); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			_ = lock.Close()
			return nil, fmt.Errorf("host socket path %s is not a socket", socketPath)
		}
		if err := os.Remove(socketPath); err != nil {
			_ = lock.Close()
			return nil, fmt.Errorf("remove stale host socket: %w", err)
		}
	}
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		_ = lock.Close()
		return nil, fmt.Errorf("listen on host socket: %w", err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = l.Close()
		_ = lock.Close()
		return nil, fmt.Errorf("chmod host socket: %w", err)
	}
	return &lockedListener{Listener: l, lock: lock}, nil
}

// lockedListener releases the host lock when the listener closes.
type lockedListener struct {
	net.Listener
	lock *os.File
	once sync.Once
}

func (l *lockedListener) Close() error {
	err := l.Listener.Close()
	l.once.Do(func() { _ = l.lock.Close() })
	return err //nolint:wrapcheck // passes the listener's own close error through
}

// Serve accepts clients on l until ctx ends or the idle exit fires. It closes
// l and every client connection on return; hosted sessions are left running.
func (s *Server) Serve(ctx context.Context, l net.Listener) error {
	acceptErr := make(chan error, 1)
	go func() {
		for {
			nc, err := l.Accept()
			if err != nil {
				acceptErr <- err
				return
			}
			if c := s.register(nc); c != nil {
				go s.handle(c)
			}
		}
	}()

	idle := time.NewTimer(s.opts.IdleExit)
	if s.opts.IdleExit <= 0 {
		idle.Stop()
	}
	defer idle.Stop()
	for {
		select {
		case <-ctx.Done():
			s.shutdown(l)
			return nil
		case err := <-acceptErr:
			s.shutdown(l)
			return fmt.Errorf("accept host client: %w", err)
		case <-s.changed:
			if s.opts.IdleExit > 0 && s.isIdle() {
				idle.Reset(s.opts.IdleExit)
			} else {
				idle.Stop()
			}
		case <-idle.C:
			// A change that raced the timer (a client just connected)
			// restarts the wait instead of ending it.
			select {
			case <-s.changed:
				if s.isIdle() {
					idle.Reset(s.opts.IdleExit)
				}
				continue
			default:
			}
			if s.isIdle() {
				s.shutdown(l)
				return nil
			}
		}
	}
}

func (s *Server) notify() {
	select {
	case s.changed <- struct{}{}:
	default:
	}
}

func (s *Server) isIdle() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.sessions) > 0 {
		return false
	}
	for c := range s.conns {
		if c.bound {
			return false
		}
	}
	return true
}

func (s *Server) register(nc net.Conn) *conn {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = nc.Close()
		return nil
	}
	c := newConn(nc)
	s.conns[c] = struct{}{}
	s.mu.Unlock()
	s.notify()
	return c
}

func (s *Server) unregister(c *conn) {
	// A taken-over connection closes itself once its last frame is out.
	if !c.finishing.Load() {
		c.close()
	}
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
	s.notify()
}

func (s *Server) shutdown(l net.Listener) {
	_ = l.Close() // ends the accept loop
	s.mu.Lock()
	s.closed = true
	conns := make([]*conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	for _, c := range conns {
		c.close()
	}
}

// handle runs one client connection: Hello, then requests until it closes.
// A dropped connection never signals its session's child.
func (s *Server) handle(c *conn) {
	var bound *session
	defer func() {
		if bound != nil {
			bound.mu.Lock()
			if bound.conn == c {
				bound.conn = nil
			}
			bound.mu.Unlock()
		}
		s.unregister(c)
	}()

	if !s.hello(c) {
		return
	}
	go c.writeLoop()

	for {
		t, p, err := ReadFrame(c.nc)
		if err != nil {
			return
		}
		switch t {
		case Launch:
			if sess := s.launch(c, bound, p); sess != nil {
				bound = sess
			}
		case Attach:
			if sess := s.attach(c, bound, p); sess != nil {
				bound = sess
			}
		case Input:
			if bound == nil {
				c.sendError("input: not attached to a session")
				continue
			}
			bound.ownerInput(p)
			if _, err := bound.ptmx.Write(p); err != nil {
				c.sendError(fmt.Sprintf("input: %v", err))
			}
		case Resize:
			s.resize(c, bound, p)
		case List:
			c.send(Listed, encode(ListResp{Sessions: s.list()}))
		case Forget:
			s.forget(c, p)
		case InputTo:
			s.inputTo(c, p)
		case PromptHint:
			s.promptHint(c, p)
		case Stop:
			s.stop(c, p)
		default:
			// Unknown frame types are skipped: the protocol grows
			// additively and app and host versions may differ.
		}
	}
}

// hello reads the client's Hello and answers it directly, before the writer
// goroutine starts. It returns false when the connection must close.
func (s *Server) hello(c *conn) bool {
	_ = c.nc.SetReadDeadline(time.Now().Add(helloTimeout))
	t, p, err := ReadFrame(c.nc)
	if err != nil {
		return false
	}
	_ = c.nc.SetReadDeadline(time.Time{})
	var h HelloMsg
	if t != Hello {
		_ = WriteFrame(c.nc, Error, encode(ErrorMsg{Message: "expected hello"}))
		return false
	}
	if err := json.Unmarshal(p, &h); err != nil || h.Version < minProtocolVersion || h.Version > ProtocolVersion {
		msg := fmt.Sprintf("unsupported protocol version %d (host speaks %d)", h.Version, ProtocolVersion)
		_ = WriteFrame(c.nc, Error, encode(ErrorMsg{Message: msg}))
		return false
	}
	return WriteFrame(c.nc, HelloOK, encode(HelloMsg{Version: ProtocolVersion, Pid: os.Getpid()})) == nil
}

func (s *Server) launch(c *conn, bound *session, p []byte) *session {
	if bound != nil {
		c.sendError("launch: connection already bound to a session")
		return nil
	}
	var req LaunchReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("launch: bad request: %v", err))
		return nil
	}
	key := sessionKey{row: req.Row, run: req.Run}
	s.mu.Lock()
	if _, ok := s.sessions[key]; ok {
		s.mu.Unlock()
		c.sendError(fmt.Sprintf("launch: session row %d run %q already exists", req.Row, req.Run))
		return nil
	}
	launch := s.launches[req.Row] + 1
	sess, err := startSession(req, launch, s.opts.RingSize, s.opts.Now())
	if err != nil {
		s.mu.Unlock()
		c.sendError(err.Error())
		return nil
	}
	if s.opts.signalGroup != nil {
		sess.signal = s.opts.signalGroup
	}
	sess.afterReap = s.opts.afterReap
	s.launches[req.Row] = launch
	s.sessions[key] = sess
	if !req.Detach {
		c.bound = true
	}
	// Bind and queue Launched before the reader starts, so it precedes
	// every Output frame.
	sess.mu.Lock()
	if !req.Detach {
		sess.conn = c
	}
	c.send(Launched, encode(sess.infoLocked()))
	sess.mu.Unlock()
	s.mu.Unlock()
	s.notify()

	go sess.readLoop()
	go s.watch(sess)
	if req.Detach {
		return nil
	}
	return sess
}

// lookup returns the session of (row, run), or nil.
func (s *Server) lookup(row int64, run string) *session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[sessionKey{row: row, run: run}]
}

// running returns the running session of (row, run, launch), or sends an
// Error naming why there is none.
func (s *Server) running(c *conn, op string, row int64, run string, launch uint64) *session {
	sess := s.lookup(row, run)
	if sess == nil {
		c.sendError(fmt.Sprintf("%s: no session row %d run %q", op, row, run))
		return nil
	}
	sess.mu.Lock()
	exited := sess.exited
	sess.mu.Unlock()
	if sess.launch != launch {
		c.sendError(fmt.Sprintf("%s: session row %d run %q is launch %d, not %d", op, row, run, sess.launch, launch))
		return nil
	}
	if exited {
		c.sendError(fmt.Sprintf("%s: session row %d run %q is not running", op, row, run))
		return nil
	}
	return sess
}

// inputTo writes to a session's PTY without binding the connection: the
// attached client (if any) keeps its session and sees the echo. The bytes are
// not the owner's typing (the phone's Interrupt Esc, say), so they never touch
// the prompt state: only an attached pane's Input does, as Desktop's
// ownerInput counts only the owner's keystrokes. Nothing is answered on
// success.
func (s *Server) inputTo(c *conn, p []byte) {
	var req InputToReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("input_to: bad request: %v", err))
		return
	}
	sess := s.running(c, "input_to", req.Row, req.Run, req.Launch)
	if sess == nil {
		return
	}
	if _, err := sess.ptmx.Write(req.Data); err != nil {
		c.sendError(fmt.Sprintf("input_to: %v", err))
	}
}

// promptHint records whether a permission dialog is up in a session; input
// while it is changes nothing in the prompt state. Nothing is answered on
// success.
func (s *Server) promptHint(c *conn, p []byte) {
	var m PromptHintMsg
	if err := json.Unmarshal(p, &m); err != nil {
		c.sendError(fmt.Sprintf("prompt_hint: bad request: %v", err))
		return
	}
	sess := s.lookup(m.Row, m.Run)
	if sess == nil {
		c.sendError(fmt.Sprintf("prompt_hint: no session row %d run %q", m.Row, m.Run))
		return
	}
	sess.setDialog(m.Dialog)
}

// stop answers Stopping once the session's group was signalled; the Exit
// follows on the attached connection and in List. A run that already exited
// is answered Stopping{already_exited: true}: nothing was signalled and its
// Exit carries no Requested.
func (s *Server) stop(c *conn, p []byte) {
	var req StopReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("stop: bad request: %v", err))
		return
	}
	sess := s.lookup(req.Row, req.Run)
	if sess == nil {
		c.sendError(fmt.Sprintf("stop: no session row %d run %q", req.Row, req.Run))
		return
	}
	if sess.launch != req.Launch {
		c.sendError(fmt.Sprintf("stop: session row %d run %q is launch %d, not %d", req.Row, req.Run, sess.launch, req.Launch))
		return
	}
	already, err := sess.stop()
	if err != nil {
		c.sendError(err.Error())
		return
	}
	c.send(Stopping, encode(StoppingMsg{AlreadyExited: already}))
}

// watch records the child's exit and delivers it to a bound connection.
// The record is kept until Forget either way: the delivery may still be
// lost (the connection drops before the client reads it), and a client
// that did read it forgets the run.
func (s *Server) watch(sess *session) {
	code := sess.wait()
	sess.mu.Lock()
	sess.exited = true
	sess.code = code
	if sess.killTime != nil {
		sess.killTime.Stop()
	}
	if sess.conn != nil {
		sess.conn.send(Exit, encode(ExitMsg{Code: code, Requested: sess.requested}))
	}
	sess.mu.Unlock()
	s.notify()
}

func (s *Server) attach(c *conn, bound *session, p []byte) *session {
	if bound != nil {
		c.sendError("attach: connection already bound to a session")
		return nil
	}
	var req AttachReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("attach: bad request: %v", err))
		return nil
	}
	s.mu.Lock()
	sess := s.sessions[sessionKey{row: req.Row, run: req.Run}]
	s.mu.Unlock()
	if sess == nil {
		c.sendError(fmt.Sprintf("attach: no session row %d run %q", req.Row, req.Run))
		return nil
	}

	sess.mu.Lock()
	c.send(Attached, encode(sess.infoLocked()))
	// An exited session replays too, so the owner sees why it ended.
	replay := append(sess.modes.ReplayPrefix(), sess.ring.Snapshot()...)
	for len(replay) > 0 {
		n := min(len(replay), MaxPayload)
		c.send(Output, replay[:n])
		replay = replay[n:]
	}
	if sess.exited {
		c.send(Exit, encode(ExitMsg{Code: sess.code, Requested: sess.requested}))
		sess.mu.Unlock()
		return nil
	}
	old := sess.conn
	sess.conn = c
	sess.mu.Unlock()
	s.mu.Lock()
	c.bound = true
	s.mu.Unlock()
	s.notify()
	if old != nil {
		// A newer attach takes the session over; the old client is told
		// why, so it does not attach back.
		old.closeWith(Error, encode(ErrorMsg{Message: TakenOver}))
	}
	return sess
}

func (s *Server) resize(c *conn, bound *session, p []byte) {
	if bound == nil {
		c.sendError("resize: not attached to a session")
		return
	}
	var req ResizeReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("resize: bad request: %v", err))
		return
	}
	// A session that already exited has no group to signal or a closed
	// PTY; resizing it is a no-op, not an error.
	if err := bound.resize(req.Cols, req.Rows); err != nil && !errors.Is(err, syscall.ESRCH) && !errors.Is(err, os.ErrClosed) {
		c.sendError(err.Error())
	}
}

func (s *Server) list() []SessionInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]SessionInfo, 0, len(s.sessions))
	for _, sess := range s.sessions {
		sess.mu.Lock()
		out = append(out, sess.infoLocked())
		sess.mu.Unlock()
	}
	slices.SortFunc(out, func(a, b SessionInfo) int {
		return cmp.Or(cmp.Compare(a.Row, b.Row), cmp.Compare(a.Run, b.Run))
	})
	return out
}

// forget drops an exited session's record. Forgetting an unknown session
// succeeds, so a client may forget after an exit the host already dropped.
func (s *Server) forget(c *conn, p []byte) {
	var req AttachReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("forget: bad request: %v", err))
		return
	}
	key := sessionKey{row: req.Row, run: req.Run}
	s.mu.Lock()
	sess := s.sessions[key]
	if sess != nil {
		sess.mu.Lock()
		running := !sess.exited
		sess.mu.Unlock()
		if running {
			s.mu.Unlock()
			c.sendError(fmt.Sprintf("forget: session row %d run %q is running", req.Row, req.Run))
			return
		}
		delete(s.sessions, key)
	}
	s.mu.Unlock()
	s.notify()
	c.send(Forgot, nil)
}

// encode marshals a protocol struct; these types always marshal.
func encode(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(fmt.Sprintf("sessionhost: encode %T: %v", v, err))
	}
	return b
}

type outFrame struct {
	t    FrameType
	p    []byte
	last bool // the writer closes the connection after it
}

// conn is one client connection. All writes after Hello go through out and
// the single writer goroutine.
type conn struct {
	nc   net.Conn
	out  chan outFrame
	done chan struct{}
	once sync.Once
	// finishing: closeWith queued the last frame; nothing else is sent.
	finishing atomic.Bool
	// bound: the connection launched or attached a session (Server.mu).
	bound bool
}

func newConn(nc net.Conn) *conn {
	return &conn{nc: nc, out: make(chan outFrame, outQueue), done: make(chan struct{})}
}

// send queues a frame without blocking; a full queue closes the connection
// so a slow client never stalls the PTY reader.
func (c *conn) send(t FrameType, p []byte) {
	if c.finishing.Load() {
		return
	}
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.out <- outFrame{t: t, p: p}:
	default:
		c.close()
	}
}

// closeWith stops reading from the connection, queues t as its last frame
// and lets the writer close the connection once that frame is written
// (within finishTimeout). Frames already queued go out before it.
func (c *conn) closeWith(t FrameType, p []byte) {
	if !c.finishing.CompareAndSwap(false, true) {
		return
	}
	_ = c.nc.SetWriteDeadline(time.Now().Add(finishTimeout))
	if rc, ok := c.nc.(interface{ CloseRead() error }); ok {
		_ = rc.CloseRead() // the old client's input no longer reaches the PTY
	}
	select {
	case c.out <- outFrame{t: t, p: p, last: true}:
	case <-c.done:
	default:
		c.close()
	}
}

func (c *conn) sendError(msg string) {
	c.send(Error, encode(ErrorMsg{Message: msg}))
}

func (c *conn) writeLoop() {
	for {
		select {
		case f := <-c.out:
			if err := WriteFrame(c.nc, f.t, f.p); err != nil || f.last {
				c.close()
				return
			}
		case <-c.done:
			return
		}
	}
}

func (c *conn) close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.nc.Close()
	})
}
