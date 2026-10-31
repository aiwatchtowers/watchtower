package sessionhost

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
)

// readChunk is the PTY read size; one read becomes one Output frame.
const readChunk = 32 << 10

// drainGrace is how long the exit path waits for the PTY reader to see the
// end of the stream after the child exited. A background process that still
// holds the terminal keeps the stream open, so the wait is bounded.
const drainGrace = 250 * time.Millisecond

// stopGrace is how long a Stop request waits after SIGHUP before it kills the
// session's process group (the same 3 s as the app's Stop Sessions).
const stopGrace = 3 * time.Second

type sessionKey struct {
	row int64
	run string
}

// session is one hosted PTY and its child.
type session struct {
	key       sessionKey
	scope     string
	agent     string
	launch    uint64
	pid       int
	startedAt time.Time
	ptmx      *os.File
	cmd       *exec.Cmd
	ring      *Ring
	readDone  chan struct{}

	mu     sync.Mutex // guards the fields below
	modes  ModeTracker
	conn   *conn
	exited bool
	code   *int
	// requested: a Stop request signalled the group; the Exit says so.
	requested bool
	// dialog: the last PromptHint said a permission dialog is up.
	dialog   bool
	killTime *time.Timer
}

// startSession launches req under a fresh PTY with exactly req.Env.
func startSession(req LaunchReq, launch uint64, ringSize int, now time.Time) (*session, error) {
	if req.Executable == "" {
		return nil, errors.New("launch: empty executable")
	}
	cmd := exec.Command(req.Executable, req.Args...) // the host runs what its owner's app asks for
	// A nil Env would make exec inherit the host's environment.
	cmd.Env = append([]string{}, req.Env...)
	cmd.Dir = req.Cwd
	ptmx, err := pty.StartWithAttrs(cmd, &pty.Winsize{Rows: req.Rows, Cols: req.Cols},
		&syscall.SysProcAttr{Setsid: true, Setctty: true})
	if err != nil {
		return nil, fmt.Errorf("launch %s: %w", req.Executable, err)
	}
	return &session{
		key:       sessionKey{row: req.Row, run: req.Run},
		scope:     req.Scope,
		agent:     req.Agent,
		launch:    launch,
		pid:       cmd.Process.Pid,
		startedAt: now,
		ptmx:      ptmx,
		cmd:       cmd,
		ring:      NewRing(ringSize),
		readDone:  make(chan struct{}),
	}, nil
}

// readLoop copies PTY output into the ring, the mode tracker and the bound
// connection until the stream ends.
func (s *session) readLoop() {
	defer close(s.readDone)
	buf := make([]byte, readChunk)
	for {
		n, err := s.ptmx.Read(buf)
		if n > 0 {
			chunk := append([]byte(nil), buf[:n]...)
			s.mu.Lock()
			s.ring.Write(chunk)
			s.modes.Observe(chunk)
			if s.conn != nil {
				s.conn.send(Output, chunk)
			}
			s.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// wait blocks until the child exits and its output is drained, then closes
// the PTY and returns the exit code (nil when killed by a signal).
func (s *session) wait() *int {
	_ = s.cmd.Wait() // the exit status is read from ProcessState below
	select {
	case <-s.readDone:
	case <-time.After(drainGrace):
	}
	// Best effort: when a background process still holds the terminal, the
	// reader is blocked in Read and the close of a non-pollable fd defers
	// until that Read returns, so Output can still follow Exit. The client
	// ignores Output after Exit.
	_ = s.ptmx.Close()
	ps := s.cmd.ProcessState
	if ps == nil {
		return nil
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return nil
	}
	code := ps.ExitCode()
	if code < 0 {
		return nil
	}
	return &code
}

// infoLocked returns the session's list entry. The caller holds s.mu.
func (s *session) infoLocked() SessionInfo {
	return SessionInfo{
		Row:         s.key.row,
		Run:         s.key.run,
		Pid:         s.pid,
		StartedAtMs: s.startedAt.UnixMilli(),
		Exited:      s.exited,
		Code:        s.code,
		Scope:       s.scope,
		Launch:      s.launch,
		Agent:       s.agent,
	}
}

// stop signals the process group SIGHUP and kills it after stopGrace unless
// the child exited by then. It marks the run requested, so its Exit carries
// Requested. A run that already exited is left alone (its exit was natural).
func (s *session) stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.exited {
		return nil
	}
	s.requested = true
	if s.killTime != nil {
		return nil // a stop is already under way
	}
	if err := syscall.Kill(-s.pid, syscall.SIGHUP); err != nil && !errors.Is(err, syscall.ESRCH) {
		return fmt.Errorf("stop: signal group: %w", err)
	}
	s.killTime = time.AfterFunc(stopGrace, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if !s.exited {
			_ = syscall.Kill(-s.pid, syscall.SIGKILL) // ESRCH: the group is already gone
		}
	})
	return nil
}

// resize sets the window size and signals the process group even when the
// size did not change, so a client can force a redraw. The ioctl runs inside
// the file's own reference (RawConn.Control) rather than on Fd(): a resize can
// race wait's Close, and Fd() would read the descriptor unsynchronised.
// Control fails only once the file is closed; that surfaces as os.ErrClosed.
func (s *session) resize(cols, rows uint16) error {
	rc, err := s.ptmx.SyscallConn()
	if err != nil {
		return fmt.Errorf("resize: %w", err)
	}
	var ioctlErr error
	if err := rc.Control(func(fd uintptr) {
		ioctlErr = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Row: rows, Col: cols})
	}); err != nil {
		return fmt.Errorf("resize: %w (%v)", os.ErrClosed, err)
	}
	if ioctlErr != nil {
		return fmt.Errorf("resize: %w", ioctlErr)
	}
	if err := syscall.Kill(-s.pid, syscall.SIGWINCH); err != nil {
		return fmt.Errorf("resize: signal group: %w", err)
	}
	return nil
}
