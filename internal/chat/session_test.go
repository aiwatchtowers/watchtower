package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// harness runs a Session over pipes and collects its events.
type harness struct {
	t       *testing.T
	in      *io.PipeWriter
	events  chan Event
	done    chan error
	runDone chan struct{} // closed once s.Run returns, so Cleanup can wait on it without racing h.done's single slot
	cancel  context.CancelFunc
}

func startSession(t *testing.T, b Backend, configure func(*Session)) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := NewSession(b, NewEventWriter(outW))
	if configure != nil {
		configure(s)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h := &harness{t: t, in: inW, events: make(chan Event, 1024), done: make(chan error, 1), runDone: make(chan struct{}), cancel: cancel}
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
		for sc.Scan() {
			var e Event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				h.events <- e
			}
		}
		close(h.events)
	}()
	go func() {
		err := s.Run(ctx, inR)
		_ = outW.Close()
		h.done <- err
		close(h.runDone)
	}()
	t.Cleanup(func() {
		cancel()
		_ = inW.Close()
		// Wait for s.Run to actually return: Session.Run closes the backend
		// (killing a real claude_backend's child and its process group) in
		// its exit defer, so a test that never called h.finish() itself must
		// still not tear down before that has happened — otherwise the kill
		// races the process exit and a later assertNoProcessSurvives can
		// catch a stub mid-escalation instead of a genuine leak.
		select {
		case <-h.runDone:
		case <-time.After(5 * time.Second):
			t.Errorf("session did not stop within 5s of cancel + stdin close")
		}
	})
	return h
}

func (h *harness) send(c Command) {
	h.t.Helper()
	b, err := json.Marshal(c)
	require.NoError(h.t, err)
	_, err = h.in.Write(append(b, '\n'))
	require.NoError(h.t, err)
}

func (h *harness) sendRaw(line string) {
	h.t.Helper()
	_, err := h.in.Write([]byte(line + "\n"))
	require.NoError(h.t, err)
}

// next returns the next event of type want, skipping others; fails after 10 s.
func (h *harness) next(want string) Event {
	h.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case e, ok := <-h.events:
			require.True(h.t, ok, "session ended before a %s event", want)
			if e.Type == want {
				return e
			}
		case <-deadline:
			h.t.Fatalf("no %s event within 10s", want)
		}
	}
}

// finish closes stdin and waits for Run to return.
func (h *harness) finish() error {
	h.t.Helper()
	_ = h.in.Close()
	select {
	case err := <-h.done:
		return err
	case <-time.After(15 * time.Second):
		h.t.Fatal("session did not stop within 15s of stdin EOF")
		return nil
	}
}

// fakeBackend scripts a Backend.
type fakeBackend struct {
	mu       sync.Mutex
	startErr error
	turn     func(ctx context.Context, c Command, emit func(Event)) error
	release  chan struct{}
	cancels  int
	closed   bool
}

func (f *fakeBackend) Start(context.Context) (string, error) { return "sess-0", f.startErr }
func (f *fakeBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	return f.turn(ctx, c, emit)
}
func (f *fakeBackend) Cancel() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancels++
	if f.release != nil {
		close(f.release)
		f.release = nil
	}
	return nil
}
func (f *fakeBackend) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	return nil
}

// ownerText strips the session's turnTimeLine off a turn's text.
func ownerText(text string) string {
	if !strings.HasPrefix(text, "[Current time: ") {
		return text
	}
	_, rest, _ := strings.Cut(text, "]\n\n")
	return rest
}

func echoTurn(_ context.Context, c Command, emit func(Event)) error {
	emit(Event{Type: EventTextDelta, Text: "echo: " + ownerText(c.Text)})
	emit(Event{Type: EventTurnDone, Status: StatusComplete})
	return nil
}

// A resumed session's system prompt holds the time it was first spawned
// (--resume never re-sends it): every turn's text must carry the time now.
func TestSession_EveryTurnCarriesTheCurrentTime(t *testing.T) {
	var got []string
	var mu sync.Mutex
	fb := &fakeBackend{turn: func(_ context.Context, c Command, emit func(Event)) error {
		mu.Lock()
		got = append(got, c.Text)
		mu.Unlock()
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		return nil
	}}
	clock := time.Now().Add(72 * time.Hour)
	h := startSession(t, fb, func(s *Session) { s.Now = func() time.Time { return clock } })
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "what did Ann say yesterday?"})
	h.next(EventTurnDone)
	clock = clock.Add(26 * time.Hour)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "and today?"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	mu.Lock()
	defer mu.Unlock()
	require.Len(t, got, 2)
	assert.Equal(t, turnTimeLine(clock.Add(-26*time.Hour))+"what did Ann say yesterday?", got[0])
	assert.Equal(t, turnTimeLine(clock)+"and today?", got[1], "the second turn carries its own time, not the first one's")
	assert.Contains(t, got[1], clock.Format("2006-01-02"))
}

func TestSession_ReadyTurnClose(t *testing.T) {
	fb := &fakeBackend{turn: echoTurn}
	h := startSession(t, fb, func(s *Session) { s.Provider, s.Model = "claude", "sonnet" })

	ready := h.next(EventSessionReady)
	assert.Equal(t, "sess-0", ready.SessionID)
	assert.Equal(t, "claude", ready.Provider)
	assert.Equal(t, "sonnet", ready.Model)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hi"})
	assert.Equal(t, "t1", h.next(EventTurnStart).TurnID)
	delta := h.next(EventTextDelta)
	assert.Equal(t, "echo: hi", delta.Text)
	assert.Equal(t, "t1", delta.TurnID, "the session stamps the turn id")
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)

	h.send(Command{Type: CommandClose})
	require.NoError(t, <-h.done)
	assert.True(t, fb.closed, "close always closes the backend")
}

func TestSession_RejectsOverlappingTurnAndCancels(t *testing.T) {
	fb := &fakeBackend{release: make(chan struct{})}
	release := fb.release
	fb.turn = func(ctx context.Context, c Command, emit func(Event)) error {
		<-release
		emit(Event{Type: EventTurnDone, Status: StatusInterrupted})
		return nil
	}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long"})
	h.next(EventTurnStart)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "second"})
	busy := h.next(EventError)
	assert.Equal(t, "t2", busy.TurnID)
	assert.Contains(t, busy.Message, "already running")

	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)
	require.NoError(t, h.finish())
	assert.Equal(t, 1, fb.cancels)
}

func TestSession_WritesTurnFileBeforeTheTurn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "turn.txt")
	read := TurnFileReader(path)
	fb := &fakeBackend{turn: func(_ context.Context, c Command, emit func(Event)) error {
		emit(Event{Type: EventTextDelta, Text: read()})
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		return nil
	}}
	h := startSession(t, fb, func(s *Session) { s.TurnFile = path })
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "turn-42", Text: "x"})
	assert.Equal(t, "turn-42", h.next(EventTextDelta).Text, "the MCP server reads the running turn from the file")
	require.NoError(t, h.finish())
}

func TestSession_BackendErrorWithoutTerminalBecomesTurnError(t *testing.T) {
	fb := &fakeBackend{turn: func(context.Context, Command, func(Event)) error {
		return errors.New("API Error: 429 rate_limit_error")
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	e := h.next(EventError)
	assert.Equal(t, "t1", e.TurnID)
	assert.Equal(t, CodeRateLimit, e.Code)
	assert.True(t, e.Retryable)
	require.NoError(t, h.finish())
}

func TestSession_ExactlyOneTerminalPerTurn(t *testing.T) {
	fb := &fakeBackend{turn: func(_ context.Context, _ Command, emit func(Event)) error {
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		emit(Event{Type: EventTextDelta, Text: "late"})
		return nil
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventTurnDone, e.Type, "a second terminal event must be dropped")
		assert.NotEqual(t, "late", e.Text, "nothing after the terminal event")
	}
}

func TestSession_StartFailureIsProviderUnavailable(t *testing.T) {
	fb := &fakeBackend{startErr: errors.New(`starting claude: exec: "claude": executable file not found in $PATH`)}
	h := startSession(t, fb, nil)
	e := h.next(EventError)
	assert.Equal(t, CodeProviderUnavailable, e.Code)
	assert.Empty(t, e.TurnID)
	assert.Error(t, <-h.done)
	assert.True(t, fb.closed, "a failed start still cleans up (temp files)")
}

func TestSession_BadCommandIsReportedAndSessionContinues(t *testing.T) {
	h := startSession(t, &fakeBackend{turn: echoTurn}, nil)
	h.next(EventSessionReady)
	h.sendRaw(`{not json`)
	assert.Equal(t, CodeInternal, h.next(EventError).Code)
	h.sendRaw(`{"type":"dance"}`)
	assert.Contains(t, h.next(EventError).Message, "unknown command")
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "still here"})
	assert.Equal(t, "echo: still here", h.next(EventTextDelta).Text)
	require.NoError(t, h.finish())
}

func TestSession_TurnWithoutIDIsRejected(t *testing.T) {
	h := startSession(t, &fakeBackend{turn: echoTurn}, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, Text: "no id"})
	assert.Contains(t, h.next(EventError).Message, "turn_id")
	require.NoError(t, h.finish())
}

// TestSession_TurnRightAfterTurnDoneIsAccepted: the app sends its next turn as
// soon as it reads turn_done, while the backend's Turn may still be returning.
// That turn must run (after the previous Turn returns), not be rejected busy.
func TestSession_TurnRightAfterTurnDoneIsAccepted(t *testing.T) {
	var mu sync.Mutex
	inTurn := 0
	fb := &fakeBackend{turn: func(_ context.Context, c Command, emit func(Event)) error {
		mu.Lock()
		inTurn++
		overlap := inTurn > 1
		mu.Unlock()
		defer func() { mu.Lock(); inTurn--; mu.Unlock() }()
		assert.False(t, overlap, "two Backend.Turn calls overlapped")
		emit(Event{Type: EventTextDelta, Text: "echo: " + ownerText(c.Text)})
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		time.Sleep(100 * time.Millisecond) // still returning after the terminal event
		return nil
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "one"})
	h.next(EventTurnDone)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "two"})
	deadline := time.After(10 * time.Second)
	for got := false; !got; {
		select {
		case e := <-h.events:
			require.NotEqual(t, EventError, e.Type, "the follow-up turn was rejected: %s", e.Message)
			if e.Type == EventTextDelta {
				assert.Equal(t, "echo: two", e.Text)
				assert.Equal(t, "t2", e.TurnID)
				got = true
			}
		case <-deadline:
			t.Fatal("no text_delta for the follow-up turn within 10s")
		}
	}
	assert.Equal(t, "t2", h.next(EventTurnDone).TurnID)
	require.NoError(t, h.finish())
}

// TestSession_CancelWhileQueuedInterruptsThatTurn: a cancel that lands while
// the next turn still waits for the previous Turn to return ends the queued
// turn as interrupted without running it.
func TestSession_CancelWhileQueuedInterruptsThatTurn(t *testing.T) {
	gate := make(chan struct{})
	var calls int
	var mu sync.Mutex
	fb := &fakeBackend{turn: func(_ context.Context, c Command, emit func(Event)) error {
		mu.Lock()
		calls++
		mu.Unlock()
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		<-gate
		return nil
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "one"})
	h.next(EventTurnDone)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "two"})
	h.send(Command{Type: CommandCancel})
	time.Sleep(50 * time.Millisecond) // let the cancel land before t1 returns
	close(gate)
	done := h.next(EventTurnDone)
	assert.Equal(t, "t2", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)
	require.NoError(t, h.finish())
	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, 1, calls, "the cancelled turn never reached the backend")
	assert.Equal(t, 0, fb.cancels, "nothing was running, so the backend is not interrupted")
}
