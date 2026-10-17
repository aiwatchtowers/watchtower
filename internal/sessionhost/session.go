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
)

// readChunk is the PTY read size; one read becomes one Output frame.
const readChunk = 32 << 10

// drainGrace is how long the exit path waits for the PTY reader to see the
// end of the stream after the child exited. A background process that still
// holds the terminal keeps the stream open, so the wait is bounded.
const drainGrace = 250 * time.Millisecond

type sessionKey struct {
	row int64
	run string
}

// session is one hosted PTY and its child.
type session struct {
	key       sessionKey
	pid       int
	startedAt time.Time
	ptmx      *os.File
	cmd       *exec.Cmd
	ring      *Ring
	readDone  chan struct{}

	mu     sync.Mutex // guards modes, conn, exited, code
	modes  ModeTracker
	conn   *conn
	exited bool
	code   *int
}

// startSession launches req under a fresh PTY with exactly req.Env.
func startSession(req LaunchReq, ringSize int, now time.Time) (*session, error) {
	if req.Executable == "" {
		return nil, errors.New("launch: empty executable")
	}
	cmd := exec.Command(req.Executable, req.Args...) //nolint:gosec // the host runs what its owner's app asks for
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
	}
}

// resize sets the window size and signals the process group even when the
// size did not change, so a client can force a redraw.
func (s *session) resize(cols, rows uint16) error {
	if err := pty.Setsize(s.ptmx, &pty.Winsize{Rows: rows, Cols: cols}); err != nil {
		return fmt.Errorf("resize: %w", err)
	}
	if err := syscall.Kill(-s.pid, syscall.SIGWINCH); err != nil {
		return fmt.Errorf("resize: signal group: %w", err)
	}
	return nil
}
