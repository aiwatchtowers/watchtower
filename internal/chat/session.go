package chat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// maxCommandBytes bounds one stdin command line (a long pasted message).
const maxCommandBytes = 8 << 20

// Backend runs turns against one provider. emit is only ever called from
// inside Turn, on Turn's goroutine.
type Backend interface {
	// Start brings the provider up (for Claude: spawns the warm process) and
	// returns the session id it resumes, if any.
	Start(ctx context.Context) (sessionID string, err error)
	// Turn sends one owner turn and emits its events until the turn ends.
	Turn(ctx context.Context, cmd Command, emit func(Event)) error
	// Cancel asks the running turn to stop.
	Cancel() error
	// Close ends the provider session and reaps every child process.
	Close() error
}

// Session is the `watchtower ai session` loop: commands on stdin, protocol-v2
// events on stdout, one turn at a time.
type Session struct {
	Provider string // reported in session_ready
	Model    string // reported in session_ready
	TurnFile string // when set, the running turn id is written here before each turn (spec §1.2)

	b Backend
	w *EventWriter

	mu  sync.Mutex
	cur *turnState // the latest turn, nil when idle
	wg  sync.WaitGroup
}

// turnState tracks one turn. A turn is "busy" until its terminal event goes
// out; the backend's Turn may still be returning after that, so the next turn
// waits for done instead of being rejected — the app sends its next turn as
// soon as it sees turn_done.
type turnState struct {
	id        string
	terminal  bool          // the terminal event was emitted (guarded by Session.mu)
	started   bool          // Backend.Turn was entered (guarded by Session.mu)
	cancelled bool          // cancel arrived before Backend.Turn was entered
	done      chan struct{} // closed once runTurn has returned
}

// NewSession wires a backend to an event writer.
func NewSession(b Backend, w *EventWriter) *Session { return &Session{b: b, w: w} }

type inbound struct {
	cmd Command
	err error
}

// Run starts the backend, emits session_ready and serves commands until
// close, stdin EOF or ctx cancellation — then cancels the running turn,
// closes the backend (reaping its processes) and waits for the turn to end.
func (s *Session) Run(ctx context.Context, in io.Reader) error {
	sid, err := s.b.Start(ctx)
	if err != nil {
		code, retry := ClassifyClaudeError(err.Error())
		if code == CodeInternal {
			code = CodeProviderUnavailable
		}
		_ = s.w.Emit(Event{Type: EventError, Code: code, Message: err.Error(), Retryable: retry})
		_ = s.b.Close()
		return err
	}
	if err := s.w.Emit(Event{Type: EventSessionReady, SessionID: sid, Provider: s.Provider, Model: s.Model}); err != nil {
		_ = s.b.Close()
		return err
	}

	done := make(chan struct{})
	cmds := make(chan inbound)
	go readCommands(in, cmds, done)

	turnCtx, cancelTurns := context.WithCancel(ctx)
	defer func() {
		close(done)
		cancelTurns()
		_ = s.b.Close()
		s.wg.Wait()
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		case m, ok := <-cmds:
			if !ok {
				return nil // stdin EOF: the app went away
			}
			if m.err != nil {
				_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: m.err.Error()})
				continue
			}
			switch m.cmd.Type {
			case CommandTurn:
				s.startTurn(turnCtx, m.cmd)
			case CommandCancel:
				s.cancel()
			case CommandClose:
				return nil
			default:
				_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: fmt.Sprintf("unknown command %q", m.cmd.Type)})
			}
		}
	}
}

func readCommands(in io.Reader, out chan<- inbound, done <-chan struct{}) {
	defer close(out)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64<<10), maxCommandBytes)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var msg inbound
		if err := json.Unmarshal(line, &msg.cmd); err != nil {
			msg.err = fmt.Errorf("invalid command: %w", err)
		}
		select {
		case out <- msg:
		case <-done:
			return
		}
	}
	if err := sc.Err(); err != nil {
		select {
		case out <- inbound{err: fmt.Errorf("reading commands: %w", err)}:
		case <-done:
		}
	}
}

func (s *Session) startTurn(ctx context.Context, c Command) {
	if c.TurnID == "" {
		_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: "turn command without turn_id"})
		return
	}
	s.mu.Lock()
	prev := s.cur
	if prev != nil && !prev.terminal {
		s.mu.Unlock()
		_ = s.w.Emit(errorEvent(c.TurnID, CodeInternal, "a turn is already running in this session", true))
		return
	}
	st := &turnState{id: c.TurnID, done: make(chan struct{})}
	s.cur = st
	s.mu.Unlock()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer func() {
			close(st.done)
			s.mu.Lock()
			if s.cur == st {
				s.cur = nil
			}
			s.mu.Unlock()
		}()
		if prev != nil {
			<-prev.done // the previous turn already ended; let its Turn return
		}
		s.runTurn(ctx, c, st)
	}()
}

// runTurn publishes the turn id, emits turn_start, runs the backend and makes
// sure exactly one terminal event (turn_done or a turn error) goes out.
func (s *Session) runTurn(ctx context.Context, c Command, st *turnState) {
	terminal := false
	emit := func(e Event) {
		if terminal {
			return
		}
		if e.TurnID == "" {
			e.TurnID = c.TurnID
		}
		if isTerminal(e) {
			terminal = true
			s.mu.Lock()
			st.terminal = true
			s.mu.Unlock()
		}
		_ = s.w.Emit(e)
	}
	if s.TurnFile != "" {
		if err := WriteTurnFile(s.TurnFile, c.TurnID); err != nil {
			emit(errorEvent(c.TurnID, CodeInternal, "recording the turn id: "+err.Error(), true))
			return
		}
	}
	_ = s.w.Emit(Event{Type: EventTurnStart, TurnID: c.TurnID})

	s.mu.Lock()
	cancelled := st.cancelled
	st.started = true
	s.mu.Unlock()
	if cancelled || ctx.Err() != nil {
		emit(Event{Type: EventTurnDone, Status: StatusInterrupted})
		return
	}

	err := s.b.Turn(ctx, c, emit)
	if terminal {
		return
	}
	emit(fallbackTerminal(ctx, c.TurnID, err))
}

// fallbackTerminal is the terminal event for a turn whose backend returned
// without emitting one. A rejected attachment is checked before ctx: stdin
// EOF right after the turn cancels turnCtx on the same race, and the
// attachment error must still win (A21).
func fallbackTerminal(ctx context.Context, turnID string, err error) Event {
	if ev, ok := attachmentErrorEvent(turnID, err); ok {
		return ev
	}
	switch {
	case ctx.Err() != nil, errors.Is(err, context.Canceled):
		return Event{Type: EventTurnDone, TurnID: turnID, Status: StatusInterrupted}
	case err == nil:
		return errorEvent(turnID, CodeInternal, "the turn ended without a result", true)
	default:
		code, retry := ClassifyClaudeError(err.Error())
		return errorEvent(turnID, code, err.Error(), retry)
	}
}

func (s *Session) cancel() {
	err := s.cancelLocked()
	if err != nil {
		_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: "cancel: " + err.Error()})
	}
}

// cancelLocked forwards the cancel under s.mu: the running turn cannot mark
// itself terminal meanwhile, so a cancel is never delivered to the backend
// after its turn ended (where it would stop the next turn instead).
func (s *Session) cancelLocked() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.cur
	if st == nil || st.terminal {
		return nil
	}
	if !st.started {
		st.cancelled = true // still waiting for the previous Turn to return
		return nil
	}
	return s.b.Cancel()
}
