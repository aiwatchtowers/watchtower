package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ownerconfirm"
)

// pipeListener is an in-memory listener: Dial hands Accept one end of a
// net.Pipe, so ServeListen runs inside testing/synctest.
type pipeListener struct {
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), closed: make(chan struct{})}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return &net.UnixAddr{Name: "pipe", Net: "unix"} }

// listenClient is one test client of the session socket.
type listenClient struct {
	t    *testing.T
	c    net.Conn
	r    *bufio.Reader
	evs  chan Event
	gone chan struct{}
}

// dial connects; greeted is false when the session closed the connection
// without its greeting.
func (l *pipeListener) dial(t *testing.T) (*listenClient, bool) {
	t.Helper()
	a, b := net.Pipe()
	l.conns <- b
	lc := &listenClient{t: t, c: a, r: bufio.NewReader(a), evs: make(chan Event, 256), gone: make(chan struct{})}
	t.Cleanup(func() { _ = a.Close() })
	line, err := lc.r.ReadBytes('\n')
	if err != nil {
		return lc, false
	}
	var g Event
	require.NoError(t, json.Unmarshal(line, &g))
	require.Equal(t, EventListenReady, g.Type)
	go func() {
		defer close(lc.gone)
		for {
			line, err := lc.r.ReadBytes('\n')
			if err != nil {
				return
			}
			var e Event
			if json.Unmarshal(line, &e) == nil {
				lc.evs <- e
			}
		}
	}()
	return lc, true
}

func (lc *listenClient) send(c Command) {
	lc.t.Helper()
	b, err := json.Marshal(c)
	require.NoError(lc.t, err)
	_, err = lc.c.Write(append(b, '\n'))
	require.NoError(lc.t, err)
}

// drain is every event received so far.
func (lc *listenClient) drain() []Event {
	var out []Event
	for {
		select {
		case e := <-lc.evs:
			out = append(out, e)
		default:
			return out
		}
	}
}

// listenRig runs ServeListen over a pipe listener with a scripted backend.
type listenRig struct {
	l    *pipeListener
	b    *fakeBackend
	done chan struct{}
	err  error
	gate chan struct{} // a "block" turn waits for it
}

func startListen(t *testing.T, verify func(context.Context, ownerconfirm.PeerToken) error, pending int,
	startErr ...error) *listenRig {
	t.Helper()
	g := &listenRig{l: newPipeListener(), done: make(chan struct{}), gate: make(chan struct{})}
	g.b = &fakeBackend{turn: func(ctx context.Context, c Command, emit func(Event)) error {
		emit(Event{Type: EventTextDelta, Text: "one "})
		if strings.HasSuffix(c.Text, "block") {
			select {
			case <-g.gate:
			case <-ctx.Done():
				return ctx.Err()
			}
			emit(Event{Type: EventTextDelta, Text: "two"})
		}
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		return nil
	}}
	if len(startErr) > 0 {
		g.b.startErr = startErr[0]
	}
	if verify == nil {
		verify = func(context.Context, ownerconfirm.PeerToken) error { return nil }
	}
	s := NewSession(g.b, NewEventWriter(nil))
	o := ListenOptions{Verify: verify, listener: g.l,
		peer:    func(net.Conn) (ownerconfirm.PeerToken, error) { return ownerconfirm.PeerToken{}, nil },
		pending: func(net.Conn) (int, error) { return pending, nil }}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); <-g.done })
	go func() {
		defer close(g.done)
		g.err = ServeListen(ctx, o, s)
	}()
	return g
}

func (g *listenRig) returned() bool {
	select {
	case <-g.done:
		return true
	default:
		return false
	}
}

// TestAISession_ListenIdleExit: with no client attached and no turn
// running the session exits after the 10-minute idle TTL; a turn that is
// still running keeps it alive however long no client is attached.
func TestAISession_ListenIdleExit(t *testing.T) {
	t.Run("turn ended", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			g := startListen(t, nil, 0)
			c, ok := g.l.dial(t)
			require.True(t, ok)
			c.send(Command{Type: CommandAttach})
			c.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hi"})
			synctest.Wait()
			assert.Contains(t, types(c.drain()), EventTurnDone)
			_ = c.c.Close()
			synctest.Wait()

			time.Sleep(ListenIdleTTL - 2*time.Second)
			synctest.Wait()
			assert.False(t, g.returned(), "still waiting for an engine")
			time.Sleep(4 * time.Second)
			synctest.Wait()
			assert.True(t, g.returned(), "exits once the TTL passed")
			assert.NoError(t, g.err)
		})
	})
	t.Run("turn running", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			g := startListen(t, nil, 0)
			c, ok := g.l.dial(t)
			require.True(t, ok)
			c.send(Command{Type: CommandAttach})
			c.send(Command{Type: CommandTurn, TurnID: "t1", Text: "block"})
			synctest.Wait()
			_ = c.c.Close()
			time.Sleep(3 * ListenIdleTTL)
			synctest.Wait()
			assert.False(t, g.returned(), "a running turn keeps the session")

			close(g.gate) // the turn ends with no engine attached
			synctest.Wait()
			time.Sleep(ListenIdleTTL + 2*time.Second)
			synctest.Wait()
			assert.True(t, g.returned())
		})
	})
}

// TestChat03_DetachedSessionBounded: a session whose engine went away mid-
// turn finishes the turn, then exits after the idle TTL with its backend
// closed (its provider processes reaped) — nothing is left running
// (BEHAVIOR CHAT-03 — see docs/inventory/chat.md).
func TestChat03_DetachedSessionBounded(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, nil, 0)
		c, ok := g.l.dial(t)
		require.True(t, ok)
		c.send(Command{Type: CommandAttach})
		c.send(Command{Type: CommandTurn, TurnID: "t1", Text: "block"})
		synctest.Wait()
		_ = c.c.Close() // the daemon restarts; no engine comes back
		close(g.gate)
		synctest.Wait()
		time.Sleep(ListenIdleTTL + 2*time.Second)
		synctest.Wait()
		require.True(t, g.returned())
		g.b.mu.Lock()
		closed := g.b.closed
		g.b.mu.Unlock()
		assert.True(t, closed, "the backend is closed on the way out")
	})
}

// TestAISession_ListenRefusesForeignPeer: a client that fails the check, or
// that wrote before the greeting, is closed without a greeting and never
// sees an event; a verified client still attaches afterwards.
func TestAISession_ListenRefusesForeignPeer(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, func(context.Context, ownerconfirm.PeerToken) error {
			return errors.New("not this team's CLI")
		}, 0)
		_, ok := g.l.dial(t)
		assert.False(t, ok, "refused before the greeting")
	})
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, nil, 1)
		_, ok := g.l.dial(t)
		assert.False(t, ok, "bytes before the greeting are refused")
	})
}

// TestAISession_ListenAttachReplaysTheTurn: a client that attaches mid-turn
// gets the session_ready and the turn's events from its start, the attached
// line naming the turn, then the rest live; a newer client replaces an
// older one.
func TestAISession_ListenAttachReplaysTheTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, nil, 0)
		a, ok := g.l.dial(t)
		require.True(t, ok)
		a.send(Command{Type: CommandAttach})
		a.send(Command{Type: CommandTurn, TurnID: "t1", Text: "block"})
		synctest.Wait()
		first := types(a.drain())
		assert.Subset(t, first, []string{EventAttached, EventSessionReady, EventTurnStart, EventTextDelta})

		b, ok := g.l.dial(t)
		require.True(t, ok)
		synctest.Wait()
		<-a.gone // replaced: the older client's connection is closed
		b.send(Command{Type: CommandAttach})
		synctest.Wait()
		got := b.drain()
		require.Equal(t, []string{EventSessionReady, EventTurnStart, EventTextDelta, EventAttached}, types(got))
		assert.Equal(t, "one ", got[2].Text)
		assert.Equal(t, "t1", got[3].TurnID)

		close(g.gate)
		synctest.Wait()
		live := b.drain()
		assert.Equal(t, []string{EventTextDelta, EventTurnDone}, types(live))
	})
}

// TestAISession_ListenStartFailureHandedToNextAttach: a backend that cannot
// start leaves its error for the engine that attaches next, then exits; a
// client's close ends a session at once even when it never attached.
func TestAISession_ListenStartFailureHandedToNextAttach(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, nil, 0, errors.New("not signed in"))
		c, ok := g.l.dial(t)
		require.True(t, ok)
		synctest.Wait()
		assert.False(t, g.returned(), "waits to hand the error over")
		c.send(Command{Type: CommandAttach})
		synctest.Wait()
		got := c.drain()
		require.Equal(t, []string{EventError, EventAttached}, types(got))
		assert.Equal(t, CodeProviderUnavailable, got[0].Code)
		assert.True(t, g.returned())
	})
	synctest.Test(t, func(t *testing.T) {
		g := startListen(t, nil, 0)
		c, ok := g.l.dial(t)
		require.True(t, ok)
		c.send(Command{Type: CommandClose})
		_ = c.c.Close()
		synctest.Wait()
		assert.True(t, g.returned())
		assert.NoError(t, g.err)
	})
}
