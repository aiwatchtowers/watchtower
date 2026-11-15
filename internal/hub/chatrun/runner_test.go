package chatrun

import (
	"context"
	"database/sql"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

const testHub = "hub-1"

type turnEnd struct {
	conv           int64
	turnID, status string
}

// rig is a runner over a fresh database with the in-process session twin.
type rig struct {
	d     *db.DB
	r     *Runner
	f     *fakeStarter
	cfg   Config
	mu    sync.Mutex
	ends  []turnEnd
	dirty map[int64]int
}

func openDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func newRig(t *testing.T, o fakeOpts) *rig {
	t.Helper()
	g := &rig{d: openDB(t), f: &fakeStarter{opts: o}, dirty: map[int64]int{}}
	g.cfg = Config{Exe: "/opt/watchtower", DBPath: "/data/watchtower.db", HubID: testHub, Dir: t.TempDir(), DB: g.d,
		Store: chatstore.New(g.d, db.ChatLeaseHub, testHub), Start: g.f.start,
		OnChange: func(conv int64) { g.mu.Lock(); g.dirty[conv]++; g.mu.Unlock() },
		OnTurnEnd: func(conv int64, turnID, status string) {
			g.mu.Lock()
			g.ends = append(g.ends, turnEnd{conv, turnID, status})
			g.mu.Unlock()
		},
	}
	g.r = New(g.cfg)
	t.Cleanup(func() { _ = g.r.Close(context.Background()) })
	return g
}

func (g *rig) turnEnds() []turnEnd {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]turnEnd(nil), g.ends...)
}

func newConversation(t *testing.T, d *db.DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func (g *rig) send(t *testing.T, conv int64, text string, routing *chatstore.Routing) chatstore.Started {
	t.Helper()
	st, err := g.r.Run(context.Background(), chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend,
		Text: text, Routing: routing})
	require.NoError(t, err)
	return st
}

type row struct {
	text, status    string
	errorCode       sql.NullString
	provider, model sql.NullString
}

func readRow(t *testing.T, d *db.DB, id int64) (row, bool) {
	t.Helper()
	var r row
	err := d.QueryRow(`SELECT text, status, error_code, provider, model FROM chat_messages WHERE id = ?`, id).
		Scan(&r.text, &r.status, &r.errorCode, &r.provider, &r.model)
	if err == sql.ErrNoRows {
		return r, false
	}
	require.NoError(t, err)
	return r, true
}

func lease(t *testing.T, d *db.DB, conv int64) *db.ChatLease {
	t.Helper()
	l, err := d.GetChatLease(conv)
	require.NoError(t, err)
	return l
}

// TestChat03Go_PoolBound: three conversations whose turns block mid-answer
// run two `ai session` children; the third waits ("Waiting for a free
// slot") and starts as soon as one turn ends — the idle session is closed
// first, so no more than two processes ever live (BEHAVIOR CHAT-03 — see
// docs/inventory/chat.md).
func TestChat03Go_PoolBound(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c1, c2, c3 := newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d)
		s1 := g.send(t, c1, "one", nil)
		g.send(t, c2, "two", nil)
		s3 := g.send(t, c3, "three", nil)
		synctest.Wait()

		alive, _ := g.f.aliveNow()
		assert.Equal(t, 2, alive)
		text, _, waiting, ok := g.r.Live(c1)
		assert.True(t, ok)
		assert.False(t, waiting)
		assert.Equal(t, "partial answer", text)
		_, _, waiting, ok = g.r.Live(c3)
		assert.True(t, ok)
		assert.True(t, waiting, "the third conversation waits for a free slot")

		procs := g.f.all()
		require.Len(t, procs, 2)
		procs[0].finish()
		synctest.Wait()

		procs = g.f.all()
		require.Len(t, procs, 3)
		assert.True(t, procs[0].isExited(), "the idle session made room")
		assert.Contains(t, procs[0].log(), "close")
		assert.False(t, procs[1].isExited(), "a running turn is never cut")
		turns := procs[2].turnCommands()
		require.Len(t, turns, 1)
		assert.Equal(t, s3.TurnID, turns[0].TurnID)
		_, _, waiting, ok = g.r.Live(c3)
		assert.True(t, ok)
		assert.False(t, waiting)
		_, maxAlive := g.f.aliveNow()
		assert.Equal(t, MaxLive, maxAlive)

		r1, _ := readRow(t, g.d, s1.AssistantMessageID)
		assert.Equal(t, chatstore.StatusComplete, r1.status)
		assert.Contains(t, g.turnEnds(), turnEnd{c1, s1.TurnID, chatstore.StatusComplete})
		_, _, _, ok = g.r.Live(c1)
		assert.False(t, ok)
	})
}

// TestChatrun_IdleEvictedForNewTurn: with both slots warm but idle, a new
// conversation's turn closes the least recently used session at once and
// never waits for a slot.
func TestChatrun_IdleEvictedForNewTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c1, c2, c3 := newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d)
		g.send(t, c1, "one", nil)
		synctest.Wait()
		time.Sleep(time.Second)
		g.send(t, c2, "two", nil)
		synctest.Wait()
		time.Sleep(time.Second)

		s3 := g.send(t, c3, "three", nil)
		_, _, waiting, ok := g.r.Live(c3)
		assert.True(t, ok)
		assert.False(t, waiting, "an idle session is evicted, so the turn is not waiting for a slot")
		synctest.Wait()

		procs := g.f.all()
		require.Len(t, procs, 3)
		assert.True(t, procs[0].isExited(), "the least recently used session was closed")
		assert.False(t, procs[1].isExited())
		assert.Equal(t, s3.TurnID, procs[2].turnCommands()[0].TurnID)
		_, maxAlive := g.f.aliveNow()
		assert.Equal(t, MaxLive, maxAlive)
		r3, _ := readRow(t, g.d, s3.AssistantMessageID)
		assert.Equal(t, chatstore.StatusComplete, r3.status)
	})
}

// TestChatrun_IdleSessionExpires: an idle session closes after IdleTTL.
func TestChatrun_IdleSessionExpires(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		g.send(t, c, "one", nil)
		synctest.Wait()
		time.Sleep(IdleTTL - time.Second)
		synctest.Wait()
		p := g.f.all()[0]
		assert.False(t, p.isExited())
		time.Sleep(time.Second)
		synctest.Wait()
		assert.True(t, p.isExited())
		assert.Contains(t, p.log(), "close")
	})
}

// TestChatrun_RemoteCancelStopsTurn: the other side's Stop (a cancel
// request on the lease) sends `cancel` within 1 s; a session that never
// answers keeps the text as `partial` 7 s later, its lease released, and is
// terminated, then killed after 3 s.
func TestChatrun_RemoteCancelStopsTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, ignoreCancel: true, ignoreTerm: true})
		c := newConversation(t, g.d)
		st := g.send(t, c, "question", nil)
		synctest.Wait()
		ok, err := g.d.RequestChatCancel(c, st.TurnID, time.Now().UnixMilli())
		require.NoError(t, err)
		require.True(t, ok)

		time.Sleep(time.Second)
		synctest.Wait()
		p := g.f.all()[0]
		assert.Contains(t, p.log(), "cancel")

		time.Sleep(CancelGrace - time.Millisecond)
		synctest.Wait()
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.NotNil(t, lease(t, g.d, c), "still running inside the grace")
		assert.NotContains(t, p.log(), "TERM")

		time.Sleep(time.Millisecond)
		synctest.Wait()
		r, _ = readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Equal(t, "partial answer", r.text)
		assert.False(t, r.errorCode.Valid)
		assert.Nil(t, lease(t, g.d, c), "the finalize released the lease")
		assert.Equal(t, []turnEnd{{c, st.TurnID, chatstore.StatusPartial}}, g.turnEnds())
		assert.Equal(t, []string{"turn", "cancel", "TERM"}, p.log(), "no polite close for a session that ignored cancel")

		time.Sleep(killAfter)
		synctest.Wait()
		assert.Equal(t, []string{"turn", "cancel", "TERM", "KILL"}, p.log())
		assert.True(t, p.isExited())
		_, _, _, ok = g.r.Live(c)
		assert.False(t, ok)
	})
}

// TestChatrun_CancelThroughRunner: Runner.Cancel reaches the session at
// once, and a session that answers ends the turn `partial` and stays warm.
func TestChatrun_CancelThroughRunner(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		st := g.send(t, c, "question", nil)
		synctest.Wait()
		ok, err := g.r.Cancel(c, st.TurnID)
		require.NoError(t, err)
		require.True(t, ok)
		synctest.Wait()
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Nil(t, lease(t, g.d, c))
		p := g.f.all()[0]
		assert.False(t, p.isExited(), "a session that answered cancel is reused")
		ok, err = g.r.Cancel(c, st.TurnID)
		require.NoError(t, err)
		assert.False(t, ok, "a cancel for an ended turn is a no-op")
	})
}

// TestChatrun_CancelQueuedTurn: a Stop of a turn still waiting for a slot
// ends it `partial` without launching anything.
func TestChatrun_CancelQueuedTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c1, c2, c3 := newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d)
		g.send(t, c1, "one", nil)
		g.send(t, c2, "two", nil)
		s3 := g.send(t, c3, "three", nil)
		synctest.Wait()
		ok, err := g.r.Cancel(c3, s3.TurnID)
		require.NoError(t, err)
		require.True(t, ok)
		synctest.Wait()
		r, _ := readRow(t, g.d, s3.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Nil(t, lease(t, g.d, c3))
		_, _, _, ok = g.r.Live(c3)
		assert.False(t, ok)
		g.f.all()[0].finish()
		synctest.Wait()
		assert.Len(t, g.f.all(), 2, "nothing launched for the cancelled turn")
	})
}

// TestChatrun_DaemonStopLeavesPartialAndSweepReleases: Close cuts a running
// turn (close, 2 s, SIGTERM): the row keeps its streamed text as `partial`
// and the lease stays; the next start's sweep releases it and marks the
// reply session_lost.
func TestChatrun_DaemonStopLeavesPartialAndSweepReleases(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, ignoreClose: true})
		c := newConversation(t, g.d)
		st := g.send(t, c, "question", nil)
		synctest.Wait()

		start := time.Now()
		require.NoError(t, g.r.Close(context.Background()))
		assert.Equal(t, closeGrace, time.Since(start))
		p := g.f.all()[0]
		assert.Equal(t, []string{"turn", "close", "TERM"}, p.log())
		assert.True(t, p.isExited())
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Equal(t, "partial answer", r.text)
		assert.False(t, r.errorCode.Valid)
		require.NotNil(t, lease(t, g.d, c), "the lease waits for the next start's sweep")
		_, err := g.r.Run(context.Background(), chatstore.StartRequest{ConversationID: c, Mode: chatstore.ModeSend, Text: "x"})
		assert.ErrorIs(t, err, ErrClosed)

		next := New(g.cfg)
		require.NoError(t, next.Sweep())
		assert.Nil(t, lease(t, g.d, c))
		r, _ = readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Equal(t, "partial answer", r.text)
		assert.Equal(t, "session_lost", r.errorCode.String)
	})
}

// TestChatrun_StartupSweepMarksSessionLost: a daemon killed mid-turn left
// the hub's lease and a `partial` reply; the sweep releases only this hub's
// leases and marks only their replies.
func TestChatrun_StartupSweepMarksSessionLost(t *testing.T) {
	d := openDB(t)
	ctx := context.Background()
	mine, mac, other := newConversation(t, d), newConversation(t, d), newConversation(t, d)
	start := func(owner db.ChatLeaseOwner, id string, conv int64) chatstore.Started {
		st, err := chatstore.New(d, owner, id).Start(ctx, chatstore.StartRequest{ConversationID: conv,
			Mode: chatstore.ModeSend, Text: "hello"})
		require.NoError(t, err)
		return st
	}
	sMine := start(db.ChatLeaseHub, testHub, mine)
	sMac := start(db.ChatLeaseDesktop, "app-1", mac)
	sOther := start(db.ChatLeaseHub, "hub-2", other)

	r := New(Config{HubID: testHub, DB: d, Dir: t.TempDir()})
	require.NoError(t, r.Sweep())

	assert.Nil(t, lease(t, d, mine))
	row, _ := readRow(t, d, sMine.AssistantMessageID)
	assert.Equal(t, chatstore.StatusPartial, row.status)
	assert.Equal(t, "session_lost", row.errorCode.String)
	owner, _ := readRow(t, d, sMine.UserMessageID)
	assert.False(t, owner.errorCode.Valid, "the owner row is not touched")
	for _, s := range []chatstore.Started{sMac, sOther} {
		assert.NotNil(t, lease(t, d, s.ConversationID))
		r, _ := readRow(t, d, s.AssistantMessageID)
		assert.False(t, r.errorCode.Valid)
	}
	require.NoError(t, r.Sweep(), "a second sweep finds nothing")
}

// TestChatrun_HeartbeatEvery15s: a running turn's lease heartbeat moves
// every 15 s, not sooner.
func TestChatrun_HeartbeatEvery15s(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		t0 := time.Now().UnixMilli()
		g.send(t, c, "question", nil)
		synctest.Wait()
		assert.Equal(t, t0, lease(t, g.d, c).HeartbeatAtMS)
		time.Sleep(HeartbeatEvery - time.Second)
		synctest.Wait()
		assert.Equal(t, t0, lease(t, g.d, c).HeartbeatAtMS)
		time.Sleep(time.Second)
		synctest.Wait()
		assert.Equal(t, t0+HeartbeatEvery.Milliseconds(), lease(t, g.d, c).HeartbeatAtMS)
		time.Sleep(HeartbeatEvery)
		synctest.Wait()
		assert.Equal(t, t0+2*HeartbeatEvery.Milliseconds(), lease(t, g.d, c).HeartbeatAtMS)
	})
}

// TestChatrun_RoutingChangeRecycles: a turn with the session's routing
// reuses the warm process (no replay; the session's session_ready recorded
// on the new reply), a provider change closes it and spawns one with the
// new argv, which replays.
func TestChatrun_RoutingChangeRecycles(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		claude := &chatstore.Routing{Provider: "claude", Model: "sonnet"}
		s1 := g.send(t, c, "one", claude)
		synctest.Wait()
		procs := g.f.all()
		require.Len(t, procs, 1)
		conv := strconv.FormatInt(c, 10)
		assert.Equal(t, []string{"ai", "session", "--conversation", conv, "--surface", "main", "--provider", "claude",
			"--model", "sonnet", "--db-path", "/data/watchtower.db"}, procs[0].argv)

		s2 := g.send(t, c, "two", nil)
		assert.False(t, s2.Replay, "the warm session answered the tip")
		synctest.Wait()
		require.Len(t, g.f.all(), 1, "the warm session is reused")
		for _, id := range []int64{s1.AssistantMessageID, s2.AssistantMessageID} {
			r, _ := readRow(t, g.d, id)
			assert.Equal(t, chatstore.StatusComplete, r.status)
			assert.Equal(t, "claude", r.provider.String)
			assert.Equal(t, "model-1", r.model.String, "each reply records the session's actual model")
		}

		s3 := g.send(t, c, "three", &chatstore.Routing{Provider: "codex", Model: "gpt"})
		assert.True(t, s3.Replay, "a new process has seen nothing")
		synctest.Wait()
		procs = g.f.all()
		require.Len(t, procs, 2)
		assert.True(t, procs[0].isExited())
		assert.Contains(t, procs[0].log(), "close")
		assert.Equal(t, []string{"ai", "session", "--conversation", conv, "--surface", "main", "--provider", "codex",
			"--model", "gpt", "--db-path", "/data/watchtower.db"}, procs[1].argv)
		turns := procs[1].turnCommands()
		require.Len(t, turns, 1)
		assert.True(t, turns[0].Replay)
		r, _ := readRow(t, g.d, s3.AssistantMessageID)
		assert.Equal(t, chatstore.StatusComplete, r.status)
	})
}

// TestChatrun_ConversationGoneClosesSession: the conversation deleted
// mid-turn (the cascade takes the lease and the rows) — the next lease read
// cancels and closes the session and nothing more is written.
func TestChatrun_ConversationGoneClosesSession(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		g.send(t, c, "question", nil)
		synctest.Wait()
		_, err := g.d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, c)
		require.NoError(t, err)

		time.Sleep(time.Second)
		synctest.Wait()
		p := g.f.all()[0]
		assert.Equal(t, []string{"turn", "cancel", "close"}, p.log())
		assert.True(t, p.isExited())
		var n int
		require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, c).Scan(&n))
		assert.Zero(t, n)
		assert.Empty(t, g.turnEnds())
		_, _, _, ok := g.r.Live(c)
		assert.False(t, ok)
	})
}

// TestChatrun_SessionDeathFinalizesLost: a session that dies mid-turn
// leaves the text `partial` with session_lost, and the next turn replays on
// a new process.
func TestChatrun_SessionDeathFinalizesLost(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		st := g.send(t, c, "question", nil)
		synctest.Wait()
		p := g.f.all()[0]
		require.NoError(t, p.Kill())
		synctest.Wait()
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		assert.Equal(t, "session_lost", r.errorCode.String)
		assert.Nil(t, lease(t, g.d, c))

		s2 := g.send(t, c, "again", nil)
		assert.True(t, s2.Replay)
		synctest.Wait()
		assert.Len(t, g.f.all(), 2)
	})
}
