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
	profile   Profile // ProfileFor(agent)
	launch    uint64
	pid       int
	startedAt time.Time
	ptmx      *os.File
	cmd       *exec.Cmd
	ring      *Ring
	readDone  chan struct{}
	signal    func(pgid int, sig syscall.Signal) error // Stop's group signal
	afterReap func()                                   // test hook: between reap and drain

	mu     sync.Mutex // guards the fields below
	modes  ModeTracker
	conn   *conn
	exited bool
	code   *int
	// reaped: cmd.Wait returned (the child is gone, its output may still
	// drain). A Stop after this point finds the exit natural.
	reaped bool
	// requested: a Stop request's SIGHUP reached the group; the Exit says so.
	requested bool
	// prompt: what the agent's prompt holds not submitted (Deliver's input).
	prompt   promptState
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
		profile:   ProfileFor(req.Agent),
		launch:    launch,
		pid:       cmd.Process.Pid,
		startedAt: now,
		ptmx:      ptmx,
		cmd:       cmd,
		ring:      NewRing(ringSize),
		readDone:  make(chan struct{}),
		signal:    killGroup,
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
	s.mu.Lock()
	s.reaped = true
	s.mu.Unlock()
	if s.afterReap != nil {
		s.afterReap()
	}
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

// ownerInput feeds one chunk of client input (an attached client's Input or
// any client's InputTo) into the prompt state. The caller writes the chunk to
// the PTY after this returns, so a delivery that checks the state under s.mu
// sees the draft before its bytes land.
func (s *session) ownerInput(b []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prompt.ownerInput(b, s.profile)
}

// setDialog records a PromptHint: whether a permission dialog is up.
func (s *session) setDialog(on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prompt.dialog = on
}

// promptHoldsText reports whether the prompt holds text not submitted (the
// owner's draft, a line left typed, or a line in its pause).
func (s *session) promptHoldsText() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.prompt.holdsText()
}

// bracketedPaste reports whether the session's terminal has bracketed paste
// on (DEC mode 2004, read from its output). Without it a delivery types
// nothing (no_paste_mode).
func (s *session) bracketedPaste() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.modes.On(bracketedPasteMode)
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

// killGroup signals a process group: the default Options.signalGroup.
func killGroup(pgid int, sig syscall.Signal) error { return syscall.Kill(-pgid, sig) }

// stop signals the process group SIGHUP and kills it after stopGrace unless
// the child was reaped by then. Only a delivered SIGHUP marks the run
// requested, so its Exit carries Requested. alreadyExited reports that the
// child was already reaped (or its group gone): nothing was signalled and the
// exit stays natural. The decision is taken under s.mu against reaped, which
// wait sets as soon as cmd.Wait returns, so a Stop during the output drain
// never marks a natural exit. A child that exits on its own in the instant
// before the SIGHUP, before it is reaped, still reads as stopped.
func (s *session) stop() (alreadyExited bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reaped || s.exited {
		return true, nil
	}
	if s.killTime != nil {
		return false, nil // a stop is already under way
	}
	if err := s.signal(s.pid, syscall.SIGHUP); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return true, nil
		}
		return false, fmt.Errorf("stop: signal group: %w", err)
	}
	s.requested = true
	s.killTime = time.AfterFunc(stopGrace, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if !s.reaped {
			_ = s.signal(s.pid, syscall.SIGKILL) // ESRCH: the group is already gone
		}
	})
	return false, nil
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
