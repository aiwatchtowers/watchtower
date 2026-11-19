package hub

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/transport"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/policy"
)

type chatPushRig struct {
	t      *testing.T
	d      *db.DB
	w      *chatPushWatch
	watch  *sources.ChatWatches
	now    time.Time
	sent   []secure.WorkAlertFields
	onRely bool
	conv   int64
}

func newChatPushRig(t *testing.T) *chatPushRig {
	t.Helper()
	r := &chatPushRig{t: t, now: time.Unix(1_800_000_000, 0), onRely: true, watch: sources.NewChatWatches()}
	r.d, _ = fileDB(t)
	res, err := r.d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('Release plan', 1, 1)`)
	if err != nil {
		t.Fatal(err)
	}
	r.conv, _ = res.LastInsertId()
	r.w = newChatPushWatch(r.d.DB, r.watch, func() bool { return r.onRely }, func() time.Time { return r.now },
		func(_ string, f secure.WorkAlertFields, _ time.Time) { r.sent = append(r.sent, f) })
	return r
}

func (r *chatPushRig) exec(q string, args ...any) {
	r.t.Helper()
	if _, err := r.d.Exec(q, args...); err != nil {
		r.t.Fatal(err)
	}
}

func (r *chatPushRig) lease(owner, turn string) {
	r.exec(`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms)
		VALUES (?, ?, 'id', ?, 1, 1)`, r.conv, owner, turn)
}

func (r *chatPushRig) release() {
	r.exec(`DELETE FROM chat_turn_leases WHERE conversation_id = ?`, r.conv)
}

func (r *chatPushRig) assistant(turn, status string) {
	r.exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id, status) VALUES (?, 'assistant', 'secret text', 1, ?, ?)`,
		r.conv, turn, status)
}

func (r *chatPushRig) check() { r.w.check(context.Background()) }

func (r *chatPushRig) only(event, body string) {
	r.t.Helper()
	if len(r.sent) != 1 {
		r.t.Fatalf("sent %d pushes, want 1: %+v", len(r.sent), r.sent)
	}
	f := r.sent[0]
	if f.Event != sources.EventChatAnswer || f.Body != body || f.Title != "Release plan" ||
		f.ConversationID != r.conv {
		r.t.Errorf("push %+v, want %s %q", f, event, body)
	}
	if want := sources.ChatAlertKey("t1", event); f.Key != want {
		r.t.Errorf("key %q, want %q", f.Key, want)
	}
}

func TestChatPush_HubTurnEndPushes(t *testing.T) {
	r := newChatPushRig(t)
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	r.only("answer", "Answer ready")

	r = newChatPushRig(t)
	r.w.turnEnded(r.conv, "t1", chatstore.StatusPartial)
	r.only("stopped", "The answer stopped")

	r = newChatPushRig(t)
	r.w.turnEnded(r.conv, "t1", chatstore.StatusError)
	r.only("stopped", "The answer stopped")
}

// TestChatPush_LeasesAreNotWatched: a lease vanishing with its turn's row
// final pushes nothing from the watch, whoever held it: every turn runs on
// the engine and pushes from its OnTurnEnd (no Desktop lease watch).
func TestChatPush_LeasesAreNotWatched(t *testing.T) {
	for _, owner := range []string{"desktop", "hub"} {
		r := newChatPushRig(t)
		r.lease(owner, "t1")
		r.check() // primes
		r.assistant("t1", "complete")
		r.release()
		r.check()
		r.check()
		if len(r.sent) != 0 {
			t.Errorf("%s: a vanished lease pushed from the watch: %+v", owner, r.sent)
		}
	}
}

// TestChatPush_EveryEngineTurnEnd: a turn the Mac app starts over chat.sock
// runs on the daemon's engine like the phone's, and its end is a
// chat_answer push with the fixed body (no text of the chat).
func TestChatPush_EveryEngineTurnEnd(t *testing.T) {
	d, _ := fileDB(t)
	path, err := mainFile(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	eng := chatengine.New(chatengine.Config{Exe: "/usr/bin/false", DBPath: path, Dir: t.TempDir(), DB: d})
	if err := eng.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close(context.Background()) })
	conv, err := eng.NewConversation(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := eng.Manage(context.Background(), chatengine.ManageRequest{Conversation: conv, Op: chatengine.ManageRename, Title: "Release plan"}); err != nil {
		t.Fatal(err)
	}
	pushed := make(chan secure.WorkAlertFields, 4)
	h := &hubRuntime{}
	h.chatPush.Store(newChatPushWatch(d.DB, sources.NewChatWatches(), func() bool { return true }, time.Now,
		func(_ string, f secure.WorkAlertFields, _ time.Time) { pushed <- f }))
	eng.OnTurnEnd(h.chatTurnEnded(func(work func()) bool { go work(); return true }))

	dir, err := os.MkdirTemp("", "wtc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := chatengine.Listen(filepath.Join(dir, chatengine.SocketName))
	if err != nil {
		t.Fatal(err)
	}
	allow := func(context.Context, ownerconfirm.PeerToken) error { return nil }
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = chatengine.NewServer(eng, chatengine.ServerOptions{VerifyApp: allow, VerifyCLI: allow}).Serve(ctx, l)
	}()
	t.Cleanup(func() { cancel(); <-served })

	c, rd, err := chatengine.Dial(ctx, filepath.Join(dir, chatengine.SocketName))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ask := func(line string) map[string]any {
		t.Helper()
		if _, err := c.Write([]byte(line + "\n")); err != nil {
			t.Fatal(err)
		}
		b, err := rd.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil || m["ok"] != true {
			t.Fatalf("answer %s %v", b, err)
		}
		return m
	}
	ask(`{"id":"1","op":"hello","params":{"protocol":1,"client":"mac"}}`)
	ask(fmt.Sprintf(`{"id":"2","op":"chat_turn","params":{"conversation_id":%d,"mode":"send","text":"secret question"}}`, conv))

	f := <-pushed // the session (/usr/bin/false) dies: the turn ends
	if f.Event != sources.EventChatAnswer || f.ConversationID != conv || f.Title != "Release plan" ||
		(f.Body != "Answer ready" && f.Body != "The answer stopped") {
		t.Fatalf("push %+v", f)
	}
}

func TestChatPush_OpenWatchSuppresses(t *testing.T) {
	r := newChatPushRig(t)
	// The phone's open request 30 s ago: looking.
	r.watch.Watch(r.conv, sources.ChatPurposeOpen, r.now.Add(-30*time.Second).Add(sources.ChatOpenWatch))
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	if len(r.sent) != 0 {
		t.Fatalf("pushed while looking: %+v", r.sent)
	}
	// 100 s ago: not looking any more.
	r = newChatPushRig(t)
	r.watch.Watch(r.conv, sources.ChatPurposeOpen, r.now.Add(-100*time.Second).Add(sources.ChatOpenWatch))
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	if len(r.sent) != 1 {
		t.Errorf("pushed %d after the window", len(r.sent))
	}
}

func TestChatPush_PrefetchDoesNotCountAsLooking(t *testing.T) {
	r := newChatPushRig(t)
	r.watch.Watch(r.conv, sources.ChatPurposePrefetch, r.now.Add(sources.ChatPrefetchHold))
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	r.only("answer", "Answer ready")
}

func TestChatPush_ApprovalWaitPushes(t *testing.T) {
	r := newChatPushRig(t)
	r.check() // primes
	r.exec(`INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, trust_at_create)
		VALUES ('send_slack_message', '{}', ?, 't1', 'pending', 'ask')`, r.conv)
	// A row that executes on its own is not a wait.
	r.exec(`INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, trust_at_create)
		VALUES ('x', '{}', ?, 't2', 'pending', 'execute')`, r.conv)
	// A row of no chat is not either.
	r.exec(`INSERT INTO agent_actions (tool, args_json, status) VALUES ('y', '{}', 'pending')`)
	r.check()
	r.only("approval", "Waiting for your approval")
	r.check()
	if len(r.sent) != 1 {
		t.Errorf("a repeat check pushed again: %d", len(r.sent))
	}
}

func TestChatPush_PendingBeforeStartIsNotNew(t *testing.T) {
	r := newChatPushRig(t)
	r.exec(`INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, trust_at_create)
		VALUES ('x', '{}', ?, 't1', 'pending', 'ask')`, r.conv)
	r.check()
	r.check()
	if len(r.sent) != 0 {
		t.Errorf("an action pending before the first look pushed: %+v", r.sent)
	}
}

func TestChatPush_NotOnRelayPushesNothing(t *testing.T) {
	r := newChatPushRig(t)
	r.onRely = false
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	if len(r.sent) != 0 {
		t.Errorf("pushed off the relay: %+v", r.sent)
	}
}

func TestChatPush_TitleClippedAndNoText(t *testing.T) {
	r := newChatPushRig(t)
	long := ""
	for i := 0; i < 90; i++ {
		long += "x"
	}
	r.exec(`UPDATE chat_conversations SET title = ? WHERE id = ?`, long, r.conv)
	r.w.turnEnded(r.conv, "t1", chatstore.StatusComplete)
	if len(r.sent) != 1 || len([]rune(r.sent[0].Title)) != 60 {
		t.Fatalf("title %+v", r.sent)
	}
	if r.sent[0].Body != "Answer ready" {
		t.Errorf("body %q", r.sent[0].Body)
	}
}

func TestChatPush_WiringBuildsTheWatch(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	if r.h.chatPush.Load() == nil || r.w.chatPush == nil {
		t.Fatal("the chat push watch is not wired")
	}
}

// A Discuss chat (context_type set) is not a main chat: neither its turn
// ends nor its approval waits push (iPhone chat spec §1).
func TestChatPush_DiscussChatNeverPushes(t *testing.T) {
	r := newChatPushRig(t)
	r.exec(`UPDATE chat_conversations SET context_type = 'meeting', context_id = '7' WHERE id = ?`, r.conv)
	r.w.turnEnded(r.conv, "t0", chatstore.StatusComplete)
	r.check() // primes
	r.exec(`INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, trust_at_create)
		VALUES ('send_slack_message', '{}', ?, 't2', 'pending', 'ask')`, r.conv)
	r.check()
	r.check()
	if len(r.sent) != 0 {
		t.Errorf("a Discuss chat pushed: %+v", r.sent)
	}
}

// TestChatPush_TurnEndRunsOffTheRunner: the runner's OnTurnEnd only hands
// the push to the hub's tracked background (the push reads the database);
// a hub that stops refuses it and nothing is pushed.
func TestChatPush_TurnEndRunsOffTheRunner(t *testing.T) {
	r := newChatPushRig(t)
	h := &hubRuntime{}
	h.chatPush.Store(r.w)
	var queued []func()
	end := h.chatTurnEnded(func(work func()) bool { queued = append(queued, work); return true })
	end(r.conv, "t1", chatstore.StatusComplete)
	if len(r.sent) != 0 || len(queued) != 1 {
		t.Fatalf("pushed on the runner's goroutine: %d sent, %d queued", len(r.sent), len(queued))
	}
	queued[0]()
	r.only("answer", "Answer ready")

	stopping := h.chatTurnEnded(func(func()) bool { return false })
	stopping(r.conv, "t2", chatstore.StatusComplete)
	if len(r.sent) != 1 {
		t.Fatalf("pushed while the hub stops: %+v", r.sent)
	}
}
