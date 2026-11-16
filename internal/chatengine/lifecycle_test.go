package chatengine

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// replayProc is an in-process stand-in for a reattached session: an attach
// is answered with its scripted replay and the attached line; close, a
// signal or a detach ends it.
type replayProc struct {
	gate      chan struct{} // when set, the attached line waits for it
	events    []chat.Event
	turnID    string // the turn its buffer holds
	inR, outR *io.PipeReader
	inW, outW *io.PipeWriter
	exited    chan struct{}
	once      sync.Once
	mu        sync.Mutex
	got       []string
}

func newReplayProc(turnID string, events []chat.Event) *replayProc {
	p := &replayProc{events: events, turnID: turnID, exited: make(chan struct{})}
	p.inR, p.inW = io.Pipe()
	p.outR, p.outW = io.Pipe()
	go p.run()
	return p
}

func (p *replayProc) run() {
	defer p.exit()
	sc := bufio.NewScanner(p.inR)
	for sc.Scan() {
		var c chat.Command
		if json.Unmarshal(sc.Bytes(), &c) != nil {
			continue
		}
		p.mu.Lock()
		p.got = append(p.got, c.Type+":"+c.TurnID+":"+c.Text+":"+strconv.FormatBool(c.Replay))
		p.mu.Unlock()
		switch c.Type {
		case chat.CommandAttach:
			for _, ev := range p.events {
				if !p.write(ev) {
					return
				}
			}
			if p.gate != nil {
				<-p.gate
			}
			if !p.write(chat.Event{Type: chat.EventAttached, TurnID: p.turnID}) {
				return
			}
		case chat.CommandClose:
			return
		}
	}
}

func (p *replayProc) write(ev chat.Event) bool {
	b, _ := json.Marshal(ev)
	_, err := p.outW.Write(append(b, '\n'))
	return err == nil
}

func (p *replayProc) turns() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.got...)
}

func (p *replayProc) exit() {
	p.once.Do(func() {
		_ = p.outW.Close()
		_ = p.inR.Close()
		close(p.exited)
	})
}

func (p *replayProc) Stdin() io.Writer        { return p.inW }
func (p *replayProc) Stdout() io.ReadCloser   { return p.outR }
func (p *replayProc) PGID() int               { return 0 }
func (p *replayProc) Terminate() error        { p.exit(); return nil }
func (p *replayProc) Kill() error             { p.exit(); return nil }
func (p *replayProc) Exited() <-chan struct{} { return p.exited }
func (p *replayProc) Detach()                 { p.exit() }

// replayRig is a database with one running engine turn (its lease and
// rows) and a session socket file for it, so an engine's Start reattaches
// through the dialSession seam.
type replayRig struct {
	d    *db.DB
	ws   string
	tmp  string
	st   chatstore.Started
	ends []turnEnd
	mu   sync.Mutex
}

func newReplayRig(t *testing.T) *replayRig {
	t.Helper()
	g := &replayRig{d: openDB(t), ws: t.TempDir(), tmp: t.TempDir()}
	conv := newConversation(t, g.d)
	st, err := chatstore.New(g.d, db.ChatLeaseHub, LeaseOwnerID).Start(context.Background(),
		chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: "question"})
	require.NoError(t, err)
	g.st = st
	dir := filepath.Join(g.ws, "chatengine", "sessions")
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, strconv.FormatInt(conv, 10)+".sock"), nil, 0o600))
	return g
}

// attach starts an engine whose reattach gets a session replaying events,
// waits until it folded them, and returns the engine and the process.
func (g *replayRig) attach(t *testing.T, events []chat.Event) (*Engine, *replayProc) {
	t.Helper()
	return g.attachGated(t, events, nil)
}

func (g *replayRig) attachGated(t *testing.T, events []chat.Event, gate chan struct{}) (*Engine, *replayProc) {
	t.Helper()
	buffered := ""
	for _, ev := range events {
		if ev.TurnID != "" {
			buffered = ev.TurnID
		}
	}
	p := newReplayProc(buffered, events)
	p.gate = gate
	e := New(Config{DB: g.d, Dir: filepath.Join(g.ws, "chatengine"), Workspace: g.ws, TempDir: g.tmp,
		dialSession: func(context.Context, string) (Process, error) { return p, nil }})
	e.OnTurnEnd(func(conv int64, turnID, status string) {
		g.mu.Lock()
		g.ends = append(g.ends, turnEnd{conv, turnID, status})
		g.mu.Unlock()
	})
	require.NoError(t, e.Start(context.Background()))
	synctest.Wait()
	return e, p
}

type storedTurn struct {
	text, status string
	errorCode    string
	steps        []string
	artifacts    int
}

func (g *replayRig) stored(t *testing.T) storedTurn {
	t.Helper()
	r, ok := readRow(t, g.d, g.st.AssistantMessageID)
	require.True(t, ok)
	out := storedTurn{text: r.text, status: r.status, errorCode: r.errorCode.String}
	rows, err := g.d.Query(`SELECT tool_id || ':' || name || ':' || COALESCE(ok, -1) || ':' || COALESCE(summary, '')
		FROM chat_turn_steps WHERE message_id = ? ORDER BY seq`, g.st.AssistantMessageID)
	require.NoError(t, err)
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out.steps = append(out.steps, s)
	}
	require.NoError(t, rows.Err())
	require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_artifacts WHERE message_id = ?`,
		g.st.AssistantMessageID).Scan(&out.artifacts))
	return out
}

func replayOf(turnID string, done bool) []chat.Event {
	ok := true
	evs := []chat.Event{
		{Type: chat.EventSessionReady, SessionID: "sid", Provider: "claude", Model: "m"},
		{Type: chat.EventTurnStart, TurnID: turnID},
		{Type: chat.EventTextDelta, TurnID: turnID, Text: "Here:\n:::artifact key=\"plan\" kind=\"document\" title=\"Plan\"\n"},
		{Type: chat.EventToolStart, TurnID: turnID, ID: "tool-1", Name: "search_knowledge", Args: json.RawMessage(`{}`)},
		{Type: chat.EventToolEnd, TurnID: turnID, ID: "tool-1", OK: &ok, Summary: "found"},
		{Type: chat.EventTextDelta, TurnID: turnID, Text: "step one\n:::\n"},
	}
	if done {
		evs = append(evs, chat.Event{Type: chat.EventTurnDone, TurnID: turnID, Status: chat.StatusComplete})
	}
	return evs
}

// TestChatengine_ReplayIsIdempotent: a turn replayed to two engines in turn
// leaves the same rows — the text set whole, the step upserted by its id;
// the replay that ends it writes the artifact once, and a later replay of
// the ended turn writes nothing.
func TestChatengine_ReplayIsIdempotent(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newReplayRig(t)
		running := replayOf(g.st.TurnID, false)
		want := "Here:\n:::artifact key=\"plan\" kind=\"document\" title=\"Plan\"\nstep one\n:::\n"

		b, _ := g.attach(t, running)
		require.NoError(t, b.Detach(context.Background()))
		first := g.stored(t)
		assert.Equal(t, want, first.text)
		assert.Equal(t, chatstore.StatusPartial, first.status)
		assert.Equal(t, []string{"tool-1:search_knowledge:1:found"}, first.steps)

		c, _ := g.attach(t, running)
		require.NoError(t, c.Detach(context.Background()))
		assert.Equal(t, first, g.stored(t), "a second replay rewrites the same rows")
		require.NotNil(t, lease(t, g.d, g.st.ConversationID), "the running turn keeps its lease")

		d, pd := g.attach(t, replayOf(g.st.TurnID, true))
		ended := g.stored(t)
		assert.Equal(t, chatstore.StatusComplete, ended.status)
		assert.Equal(t, want, ended.text)
		assert.Equal(t, first.steps, ended.steps)
		assert.Equal(t, 1, ended.artifacts)
		assert.Nil(t, lease(t, g.d, g.st.ConversationID))
		<-pd.Exited() // an adopted session closes once idle
		require.NoError(t, d.Detach(context.Background()))

		e, pe := g.attach(t, replayOf(g.st.TurnID, true))
		<-pe.Exited()
		require.NoError(t, e.Detach(context.Background()))
		assert.Equal(t, ended, g.stored(t), "an ended turn's replay writes nothing")
		assert.Equal(t, []turnEnd{{g.st.ConversationID, g.st.TurnID, chatstore.StatusComplete}}, g.ends)
	})
}

// TestChatengine_ReattachedSessionGetsItsUnsentTurn: the lease holds a turn
// the session never got (the engine went away while it was binding): the
// next engine sends it, rebuilt from the owner row and replayed.
func TestChatengine_ReattachedSessionGetsItsUnsentTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newReplayRig(t)
		e, p := g.attach(t, []chat.Event{{Type: chat.EventSessionReady, SessionID: "sid", Provider: "claude"}})
		assert.Contains(t, p.turns(), "turn:"+g.st.TurnID+":question:true")
		require.NotNil(t, lease(t, g.d, g.st.ConversationID), "the turn runs on")
		require.NoError(t, e.Detach(context.Background()))
		got := g.stored(t)
		assert.Equal(t, chatstore.StatusPartial, got.status)
		assert.Empty(t, got.errorCode)
	})
}

// TestChatengine_ReplayNeverShrinksStoredText: until the replay is whole
// (its attached line) the reattached turn writes nothing, so the row keeps
// the longer text the earlier engine flushed.
func TestChatengine_ReplayNeverShrinksStoredText(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newReplayRig(t)
		b, _ := g.attach(t, replayOf(g.st.TurnID, false))
		require.NoError(t, b.Detach(context.Background()))
		whole := g.stored(t).text

		gate := make(chan struct{})
		c, _ := g.attachGated(t, replayOf(g.st.TurnID, false), gate)
		assert.Equal(t, whole, g.stored(t).text, "the first replayed delta is not written alone")
		time.Sleep(2 * chatstore.FlushInterval) // ticks pass mid-replay
		synctest.Wait()
		assert.Equal(t, whole, g.stored(t).text, "no fragment written over the row")
		close(gate)
		synctest.Wait()
		assert.Equal(t, whole, g.stored(t).text)
		require.NoError(t, c.Detach(context.Background()))
	})
}

// TestChatengine_DetachLeavesSessionsAndLease: Detach flushes the running
// turn's text and drops the connection; the process gets no close and no
// signal, the reply stays `partial` with no error and the lease stays for
// the next engine.
func TestChatengine_DetachLeavesSessionsAndLease(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "half"})
		c := newConversation(t, g.d)
		st := g.send(t, c, "question", nil)
		synctest.Wait()
		start := time.Now()
		require.NoError(t, g.r.Detach(context.Background()))
		assert.Zero(t, time.Since(start), "a restart never waits for a turn")
		p := g.f.all()[0]
		assert.Equal(t, []string{"turn"}, p.log(), "no cancel, close or signal")
		assert.False(t, p.isExited())
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, "half", r.text)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.False(t, r.errorCode.Valid)
		require.NotNil(t, lease(t, g.d, c))
		_ = p.Kill() // the stand-in ends with the test
		synctest.Wait()
	})
}

// TestChatengine_ShutdownReapsSessions: Shutdown cancels every running
// turn, ends it `partial` with its text (no error, lease released), then
// closes each session; one that ignores close gets SIGTERM 2 s later and
// SIGKILL 3 s after that. The engine keeps taking turns afterwards.
func TestChatengine_ShutdownReapsSessions(t *testing.T) {
	t.Run("polite", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			g := newRig(t, fakeOpts{block: true, text: "half"})
			c1, c2 := newConversation(t, g.d), newConversation(t, g.d)
			s1, s2 := g.send(t, c1, "a", nil), g.send(t, c2, "b", nil)
			synctest.Wait()
			start := time.Now()
			require.NoError(t, g.r.Shutdown(context.Background()))
			assert.Zero(t, time.Since(start))
			for _, p := range g.f.all() {
				assert.Equal(t, []string{"turn", "cancel", "close"}, p.log())
				assert.True(t, p.isExited())
			}
			for _, st := range []chatstore.Started{s1, s2} {
				r, _ := readRow(t, g.d, st.AssistantMessageID)
				assert.Equal(t, chatstore.StatusPartial, r.status)
				assert.Equal(t, "half", r.text)
				assert.False(t, r.errorCode.Valid)
				assert.Nil(t, lease(t, g.d, st.ConversationID))
			}
			assert.Len(t, g.turnEnds(), 2)

			// The engine stays open: a new turn runs on a new session.
			again, err := g.r.Turn(context.Background(), turnReq(c1, "again", ""))
			require.NoError(t, err)
			synctest.Wait()
			require.Len(t, g.f.all(), 3)
			g.f.all()[2].finish()
			synctest.Wait()
			r, _ := readRow(t, g.d, again.AssistantMessageID)
			assert.Equal(t, chatstore.StatusComplete, r.status)
		})
	})
	t.Run("stubborn", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			g := newRig(t, fakeOpts{block: true, ignoreCancel: true, ignoreClose: true, ignoreTerm: true})
			c := newConversation(t, g.d)
			st := g.send(t, c, "a", nil)
			synctest.Wait()
			done := make(chan struct{})
			start := time.Now()
			go func() {
				defer close(done)
				assert.NoError(t, g.r.Shutdown(context.Background()))
			}()
			p := g.f.all()[0]
			time.Sleep(closeGrace - time.Millisecond)
			synctest.Wait()
			assert.Equal(t, []string{"turn", "cancel", "close"}, p.log())
			time.Sleep(time.Millisecond)
			synctest.Wait()
			assert.Equal(t, []string{"turn", "cancel", "close", "TERM"}, p.log(), "SIGTERM at 2 s")
			time.Sleep(killAfter)
			synctest.Wait()
			<-done
			assert.Equal(t, []string{"turn", "cancel", "close", "TERM", "KILL"}, p.log(), "SIGKILL 3 s later")
			assert.Equal(t, closeGrace+killAfter, time.Since(start))
			r, _ := readRow(t, g.d, st.AssistantMessageID)
			assert.Equal(t, chatstore.StatusPartial, r.status)
			assert.Nil(t, lease(t, g.d, c))
		})
	})
}

// TestChatengine_ShutdownOpRefusesRelayClients: chat_shutdown is the Mac
// app's and the CLI's only.
func TestChatengine_ShutdownOpRefusesRelayClients(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		_, err := g.r.Do(context.Background(), opShutdown, nil, Client{Kind: "phone"})
		assert.ErrorIs(t, err, ErrForbidden)
		_, err = g.r.Do(context.Background(), opShutdown, nil, Client{Kind: clientCLI})
		assert.NoError(t, err)
	})
}
