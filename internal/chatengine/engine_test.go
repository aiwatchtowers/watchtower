package chatengine

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// turnReq is a send of text to conv with key ("" = none).
func turnReq(conv int64, text, key string) TurnRequest {
	return TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: text},
		ClientKey: key}
}

func countRows(t *testing.T, d *db.DB, where string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE `+where, args...).Scan(&n))
	return n
}

func ownerRows(t *testing.T, d *db.DB, conv int64) int {
	t.Helper()
	return countRows(t, d, `conversation_id = ? AND role = 'user'`, conv)
}

// drain is every event queued on sub right now.
func drain(sub *Subscription) []Event {
	var out []Event
	for {
		select {
		case ev, ok := <-sub.Events:
			if !ok {
				return out
			}
			out = append(out, ev)
		default:
			return out
		}
	}
}

// stamped is an event and when the subscriber got it.
type stamped struct {
	at time.Time
	ev Event
}

// recorder reads sub on its own goroutine, stamping each event.
type recorder struct {
	mu   sync.Mutex
	got  []stamped
	done chan struct{}
}

func record(sub *Subscription) *recorder {
	r := &recorder{done: make(chan struct{})}
	go func() {
		defer close(r.done)
		for ev := range sub.Events {
			r.mu.Lock()
			r.got = append(r.got, stamped{time.Now(), ev})
			r.mu.Unlock()
		}
	}()
	return r
}

func (r *recorder) of(typ string) []stamped {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []stamped
	for _, s := range r.got {
		if s.ev.Type == typ {
			out = append(out, s)
		}
	}
	return out
}

// assertSpaced: no two batches of evs closer than window (one batch = one
// instant).
func assertSpaced(t *testing.T, evs []stamped, window time.Duration) {
	t.Helper()
	for i := 1; i < len(evs); i++ {
		if gap := evs[i].at.Sub(evs[i-1].at); gap != 0 {
			assert.GreaterOrEqual(t, gap, window, "event %d came %s after the previous batch", i, gap)
		}
	}
}

// TestChatengine_SecondTurnBusy: a second turn on a conversation whose turn
// runs is refused busy, and only one owner row exists.
func TestChatengine_SecondTurnBusy(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		_, err := g.r.Turn(context.Background(), turnReq(c, "one", ""))
		require.NoError(t, err)
		synctest.Wait()
		_, err = g.r.Turn(context.Background(), turnReq(c, "two", "k2"))
		require.ErrorIs(t, err, chatstore.ErrBusy)
		assert.Equal(t, "busy", ErrorCode(err))
		_, err = g.r.Do(context.Background(), "chat_turn",
			json.RawMessage(`{"conversation_id":`+itoa(c)+`,"mode":"send","text":"three"}`), Client{Kind: "phone"})
		assert.Equal(t, "busy", ErrorCode(err))
		assert.Equal(t, 1, ownerRows(t, g.d, c))
	})
}

// TestChat01_RefusedTurnWritesNothing: a refused turn — busy, invalid, its
// conversation gone — leaves chat_messages as it was (BEHAVIOR CHAT-01 —
// see docs/inventory/chat.md).
func TestChat01_RefusedTurnWritesNothing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		_, err := g.r.Turn(context.Background(), turnReq(c, "one", ""))
		require.NoError(t, err)
		synctest.Wait()
		before := countRows(t, g.d, `1 = 1`)

		idle := newConversation(t, g.d)
		for _, r := range []struct {
			req  TurnRequest
			code string
		}{
			{turnReq(c, "busy", "k-busy"), "busy"},
			{turnReq(idle, "   ", "k-blank"), "invalid"},
			{TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: idle, Mode: chatstore.ModeRegenerate,
				MessageID: 999_999}}, "not_found"},
			{turnReq(idle+100, "gone", "k-gone"), "not_found"},
		} {
			_, err := g.r.Turn(context.Background(), r.req)
			require.Error(t, err)
			assert.Equal(t, r.code, ErrorCode(err))
			assert.Equal(t, before, countRows(t, g.d, `1 = 1`), "a %s refusal wrote nothing", r.code)
		}
	})
}

// TestChatengine_RepeatedClientKeyAppliesOnce: the same client key twice —
// while the turn runs and after it ended — answers the same turn and writes
// one owner row.
func TestChatengine_RepeatedClientKeyAppliesOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		st1, err := g.r.Turn(context.Background(), turnReq(c, "hello", "key-1"))
		require.NoError(t, err)
		synctest.Wait()
		st2, err := g.r.Turn(context.Background(), turnReq(c, "hello", "key-1"))
		require.NoError(t, err, "a repeat while the turn runs is not busy")
		assert.Equal(t, [3]any{st1.UserMessageID, st1.AssistantMessageID, st1.TurnID},
			[3]any{st2.UserMessageID, st2.AssistantMessageID, st2.TurnID})

		g.f.all()[0].finish()
		synctest.Wait()
		st3, err := g.r.Turn(context.Background(), turnReq(c, "hello", "key-1"))
		require.NoError(t, err)
		assert.Equal(t, [3]any{st1.UserMessageID, st1.AssistantMessageID, st1.TurnID},
			[3]any{st3.UserMessageID, st3.AssistantMessageID, st3.TurnID})
		assert.Equal(t, 1, ownerRows(t, g.d, c))
		assert.Len(t, g.turnEnds(), 1, "one turn ran")
	})
}

// TestChatengine_ClientKeySurvivesRestart: a key applied by an engine that
// closed is answered by the next one from the database, and a duplicate
// inserted between the lookup and the start transaction (another writer) is
// answered the same way through the unique index.
func TestChatengine_ClientKeySurvivesRestart(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		stA, err := g.r.Turn(context.Background(), turnReq(c, "hello", "key-a"))
		require.NoError(t, err)
		synctest.Wait()
		require.NoError(t, g.r.Close(context.Background()))

		b := g.newEngine()
		t.Cleanup(func() { _ = b.Close(context.Background()) })
		require.NoError(t, b.Start(context.Background()))
		rows := countRows(t, g.d, `conversation_id = ?`, c)
		stB, err := b.Turn(context.Background(), turnReq(c, "hello", "key-a"))
		require.NoError(t, err)
		assert.Equal(t, [3]any{stA.UserMessageID, stA.AssistantMessageID, stA.TurnID},
			[3]any{stB.UserMessageID, stB.AssistantMessageID, stB.TurnID})
		assert.Equal(t, rows, countRows(t, g.d, `conversation_id = ?`, c))

		// The racing writer: its owner row and reply carry key-b once the
		// engine looked the key up and found nothing.
		var owner, reply int64
		b.beforeStart = func() {
			res, err := g.d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id, client_key)
				VALUES (?, 'user', 'hello', 2, 'turn-b', 'key-b')`, c)
			require.NoError(t, err)
			owner, _ = res.LastInsertId()
			res, err = g.d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status)
				VALUES (?, ?, 'assistant', '', 2, 'turn-b', 'partial')`, c, owner)
			require.NoError(t, err)
			reply, _ = res.LastInsertId()
		}
		rows = countRows(t, g.d, `conversation_id = ?`, c) + 2
		stDup, err := b.Turn(context.Background(), turnReq(c, "hello", "key-b"))
		require.NoError(t, err)
		assert.Equal(t, [3]any{owner, reply, "turn-b"}, [3]any{stDup.UserMessageID, stDup.AssistantMessageID, stDup.TurnID})
		assert.Equal(t, rows, countRows(t, g.d, `conversation_id = ?`, c), "the refused insert left nothing")
		assert.Nil(t, lease(t, g.d, c), "the refused start's lease claim rolled back")
	})
}

// TestChatengine_SubscriberSeesForeignTurnLive: the Mac's subscription sees
// a turn the phone started, with its live text (G6).
func TestChatengine_SubscriberSeesForeignTurnLive(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "streaming now"})
		c := newConversation(t, g.d)
		sub := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer sub.Close()
		synctest.Wait()
		first := drain(sub)
		require.Len(t, first, 1)
		assert.Equal(t, EventSnapshot, first[0].Type)

		_, err := g.r.Do(context.Background(), "chat_turn",
			json.RawMessage(`{"conversation_id":`+itoa(c)+`,"mode":"send","text":"hi","client_key":"p-1"}`), Client{Kind: "phone"})
		require.NoError(t, err)
		synctest.Wait()
		time.Sleep(FeedCoalesce)
		synctest.Wait()
		var live string
		for _, ev := range drain(sub) {
			if ev.Type == EventMessageUpsert && ev.Message.Role == "assistant" {
				live = ev.Message.Text
			}
		}
		assert.Equal(t, "streaming now", live)
	})
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

// TestChatengine_FeedCoalescedAt150ms: 20 text deltas in 100 ms reach a
// subscriber as at most one message_upsert per 150 ms window, and the last
// one carries the whole text.
func TestChatengine_FeedCoalescedAt150ms(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "a"})
		c := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		sub := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer sub.Close()
		rec := record(sub)
		synctest.Wait()

		p := g.f.all()[0]
		want := "a"
		for range 19 {
			p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: st.TurnID, Text: "b"})
			want += "b"
			time.Sleep(5 * time.Millisecond)
		}
		time.Sleep(time.Second)
		synctest.Wait()

		upserts := rec.of(EventMessageUpsert)
		require.NotEmpty(t, upserts)
		assert.LessOrEqual(t, len(upserts), 2, "100 ms of deltas span at most two windows")
		assertSpaced(t, upserts, FeedCoalesce)
		last := upserts[len(upserts)-1].ev.Message
		assert.Equal(t, st.AssistantMessageID, last.ID)
		assert.Equal(t, want, last.Text)
	})
}

// TestChatengine_ListCoalescedAt500ms: 20 list changes in 100 ms reach a list
// subscriber as at most one list_update per 500 ms window, the last one with
// the final state.
func TestChatengine_ListCoalescedAt500ms(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		convs := []int64{newConversation(t, g.d), newConversation(t, g.d)}
		sub := g.r.Subscribe(Target{List: true}, Client{Kind: "mac"})
		defer sub.Close()
		rec := record(sub)
		synctest.Wait()

		for i := range 20 {
			op := ManagePin
			if i%2 == 1 {
				op = ManageUnpin
			}
			require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: convs[i%2], Op: op}))
			time.Sleep(5 * time.Millisecond)
		}
		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: convs[1], Op: ManagePin}))
		time.Sleep(2 * time.Second)
		synctest.Wait()

		updates := rec.of(EventListUpdate)
		require.NotEmpty(t, updates)
		assert.LessOrEqual(t, len(updates), 2, "about 100 ms of changes span at most two windows")
		assertSpaced(t, updates, ListCoalesce)
		pinned := map[int64]bool{}
		for _, row := range updates[len(updates)-1].ev.List.Conversations {
			pinned[row.ID] = row.Pinned
		}
		assert.Equal(t, map[int64]bool{convs[0]: true, convs[1]: true}, pinned)
	})
}

// TestChatengine_SlowSubscriberResyncsAndSeesTurnEnd: a subscriber that reads
// nothing while more than 256 events pile up gets the 256, then one resync,
// then a snapshot holding the turn's final status.
func TestChatengine_SlowSubscriberResyncsAndSeesTurnEnd(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "x"})
		c := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		sub := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer sub.Close()
		synctest.Wait()

		p := g.f.all()[0]
		for range subscriptionQueue + 20 {
			p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: st.TurnID, Text: "y"})
			time.Sleep(FeedCoalesce + 10*time.Millisecond)
		}
		p.finish()
		time.Sleep(time.Second)
		synctest.Wait()

		var got []Event
		for len(got) < subscriptionQueue+2 {
			got = append(got, <-sub.Events)
			synctest.Wait()
		}
		assert.Equal(t, EventSnapshot, got[0].Type)
		for _, ev := range got[1:subscriptionQueue] {
			assert.Equal(t, EventMessageUpsert, ev.Type)
		}
		require.Equal(t, EventResync, got[subscriptionQueue].Type)
		snap := got[subscriptionQueue+1]
		require.Equal(t, EventSnapshot, snap.Type)
		require.NotNil(t, snap.Snapshot)
		msgs := snap.Snapshot.Messages
		require.NotEmpty(t, msgs)
		assert.Equal(t, st.AssistantMessageID, msgs[len(msgs)-1].ID)
		assert.Equal(t, chatstore.StatusComplete, msgs[len(msgs)-1].Status)
		assert.Empty(t, drain(sub), "nothing after the snapshot: the turn is over")
	})
}

// TestChatengine_DeleteDuringTurnCancels: a delete mid-turn cancels the turn
// and closes its session; nothing of the turn is written after the delete
// committed.
func TestChatengine_DeleteDuringTurnCancels(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		p := g.f.all()[0]

		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: c, Op: ManageDelete}))
		synctest.Wait()
		assert.Contains(t, p.log(), "cancel", "the delete cancels at once, not at the next lease read")
		p.emit(chat.Event{Type: chat.EventToolStart, TurnID: st.TurnID, ID: "tool-1", Name: "search_knowledge"})
		p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: st.TurnID, Text: " more"})
		time.Sleep(3 * time.Second)
		synctest.Wait()

		assert.True(t, p.isExited())
		assert.Zero(t, countRows(t, g.d, `conversation_id = ?`, c))
		var steps int
		require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_turn_steps`).Scan(&steps))
		assert.Zero(t, steps)
		_, _, _, ok := g.r.Live(c)
		assert.False(t, ok)
	})
}

// TestChatengine_ClaimsLegacyLeaseForOneRelease: a running turn holds the
// chat_turn_leases row as owner hub, id chatengine, its heartbeat moving
// every 15 s; the turn's end releases it.
func TestChatengine_ClaimsLegacyLeaseForOneRelease(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		t0 := time.Now().UnixMilli()
		_, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		l := lease(t, g.d, c)
		require.NotNil(t, l)
		assert.Equal(t, db.ChatLeaseHub, l.Owner)
		assert.Equal(t, LeaseOwnerID, l.OwnerID)
		assert.Equal(t, t0, l.HeartbeatAtMS)
		time.Sleep(HeartbeatEvery)
		synctest.Wait()
		assert.Equal(t, t0+HeartbeatEvery.Milliseconds(), lease(t, g.d, c).HeartbeatAtMS)
		time.Sleep(HeartbeatEvery)
		synctest.Wait()
		assert.Equal(t, t0+2*HeartbeatEvery.Milliseconds(), lease(t, g.d, c).HeartbeatAtMS)

		g.f.all()[0].finish()
		synctest.Wait()
		assert.Nil(t, lease(t, g.d, c))
	})
}

// TestChatengine_SessionReadyPublishesRoutingLive: the routing a session
// reports in its session_ready reaches a subscriber as conversation_update
// (the engine's own events, no database watch), and the list follows.
func TestChatengine_SessionReadyPublishesRoutingLive(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		feed := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer feed.Close()
		list := g.r.Subscribe(Target{List: true}, Client{Kind: "mac"})
		defer list.Close()
		synctest.Wait()
		drain(feed)
		drain(list)

		st, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		g.f.all()[0].emit(chat.Event{Type: chat.EventSessionReady, Provider: "codex", Model: "gpt-x", RoutingMode: "pinned"})
		time.Sleep(time.Second)
		synctest.Wait()

		var conv *FeedConversation
		var note *Part
		for _, ev := range drain(feed) {
			if ev.Type == EventConversationUpdate {
				conv = ev.ConversationUpdate
			}
			if ev.Type == EventMessageUpsert && ev.Message.Role == "assistant" {
				for _, p := range ev.Message.Parts {
					if p.Kind == PartRoutingNote {
						note = &p
					}
				}
			}
		}
		require.NotNil(t, conv, "a conversation_update came")
		require.NotNil(t, note, "the live assistant message gained a routing_note part without a database re-read")
		assert.Equal(t, "Current provider: codex · gpt-x", note.Fallback.Text)
		assert.JSONEq(t, `{"mode":"pinned","provider":"codex","model":"gpt-x","actual_provider":"codex","actual_model":"gpt-x"}`, string(note.Payload))
		assert.Equal(t, "pinned", conv.Routing.Mode)
		require.NotNil(t, conv.Routing.Provider)
		assert.Equal(t, "codex", *conv.Routing.Provider)
		assert.Equal(t, "codex", conv.ActualProvider)
		assert.Equal(t, "gpt-x", conv.ActualModel)
		var rows []ListConversation
		for _, ev := range drain(list) {
			if ev.Type == EventListUpdate {
				rows = ev.List.Conversations
			}
		}
		require.Len(t, rows, 1, "a list_update came")
		assert.Equal(t, StateAnswering, rows[0].State)
		assert.NotEmpty(t, st.TurnID)
	})
}

// TestChat04_EngineSessionArgvCarriesNoContent: the session's argv holds
// flags only; the owner's text and files travel on stdin (BEHAVIOR CHAT-04
// — see docs/inventory/chat.md).
func TestChat04_EngineSessionArgvCarriesNoContent(t *testing.T) {
	for _, cfg := range []sessionConfig{{automatic: true}, {provider: "claude", model: "sonnet", project: 4}} {
		args := strings.Join(cfg.argv(7, "/data/watchtower.db"), " ")
		assert.NotContains(t, args, "--resume")
		assert.NotContains(t, args, "SECRET")
	}
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		_, err := g.r.Turn(context.Background(), turnReq(c, "SECRET-TEXT", ""))
		require.NoError(t, err)
		synctest.Wait()
		p := g.f.all()[0]
		assert.NotContains(t, strings.Join(p.argv, " "), "SECRET")
		turns := p.turnCommands()
		require.Len(t, turns, 1)
		assert.Contains(t, turns[0].Text, "SECRET-TEXT")
	})
}

// TestChatengine_SendAfterStopReplaysSavedText: a stopped turn keeps its
// streamed text as `partial`; the next send starts after it with no
// --resume (the history replays from the database).
func TestChatengine_SendAfterStopReplaysSavedText(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "half"})
		c := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(c, "q", ""))
		require.NoError(t, err)
		synctest.Wait()
		ok, err := g.r.Cancel(c, st.TurnID)
		require.NoError(t, err)
		require.True(t, ok)
		synctest.Wait()

		_, err = g.r.Turn(context.Background(), turnReq(c, "again", ""))
		require.NoError(t, err)
		synctest.Wait()
		r, _ := readRow(t, g.d, st.AssistantMessageID)
		assert.Equal(t, "half", r.text)
		assert.Equal(t, chatstore.StatusPartial, r.status)
		for _, p := range g.f.all() {
			assert.NotContains(t, p.argv, "--resume")
		}
	})
}

// TestChatengine_FailedReadRetriesNeverFakes: while the subscription's reads
// fail it sends nothing — no empty snapshot standing in for the chat — and
// tries again each window, so the snapshot and a turn's final status still
// arrive once reads work, with no other change to wake it.
func TestChatengine_FailedReadRetriesNeverFakes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "answer"})
		c := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(c, "go", ""))
		require.NoError(t, err)
		synctest.Wait()

		var failing atomic.Bool
		failing.Store(true)
		fail := func() error {
			if failing.Load() {
				return errors.New("disk I/O error")
			}
			return nil
		}
		g.r.failReads.Store(&fail)
		feed := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer feed.Close()
		list := g.r.Subscribe(Target{List: true}, Client{Kind: "mac"})
		defer list.Close()
		time.Sleep(2 * ListCoalesce)
		synctest.Wait()
		assert.Empty(t, drain(feed), "no snapshot while the read fails")
		assert.Empty(t, drain(list), "no list while the read fails")

		failing.Store(false)
		time.Sleep(ListCoalesce)
		synctest.Wait()
		got := drain(feed)
		require.Len(t, got, 1)
		require.Equal(t, EventSnapshot, got[0].Type)
		require.NotNil(t, got[0].Snapshot)
		assert.Equal(t, c, got[0].Snapshot.Conversation.ID, "a real snapshot, not an empty stand-in")
		lists := drain(list)
		require.Len(t, lists, 1)
		require.NotNil(t, lists[0].List)
		assert.Len(t, lists[0].List.Conversations, 1)

		// The turn ends while reads fail: the change is kept, not dropped.
		failing.Store(true)
		g.f.all()[0].finish()
		time.Sleep(time.Second)
		synctest.Wait()
		assert.Empty(t, drain(feed))
		failing.Store(false)
		time.Sleep(FeedCoalesce)
		synctest.Wait()
		var final string
		for _, ev := range drain(feed) {
			if ev.Type == EventMessageUpsert && ev.Message.ID == st.AssistantMessageID {
				final = ev.Message.Status
			}
		}
		assert.Equal(t, chatstore.StatusComplete, final)
	})
}
