package hub

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

type chatRig struct {
	t         *testing.T
	h         *hubRuntime
	w         *wiring
	st        *state.Store
	d         *db.DB
	now       time.Time
	published [][]hubslices.Kind
}

// newChatRig builds a hub's wiring over a database file in mode, on a
// transport of kind (the hub's only one: no switcher).
func newChatRig(t *testing.T, mode string, kind transport.Kind) *chatRig {
	t.Helper()
	return newChatRigWith(t, mode, kind, func(*Options) {})
}

func newChatRigWith(t *testing.T, mode string, kind transport.Kind, edit func(*Options)) *chatRig {
	t.Helper()
	r := &chatRig{t: t, now: time.Unix(1_800_000_000, 0)}
	r.d, _ = fileDB(t)
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	r.st = st
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	clock := func() time.Time { return r.now }
	o := Options{DB: r.d, Clock: clock, Dir: t.TempDir(), RecordingsDir: t.TempDir(),
		published: func(k []hubslices.Kind) { r.published = append(r.published, k) }}
	edit(&o)
	r.h = &hubRuntime{sup: &supervisor{o: o}, st: st, kr: kr, mode: mode, tr: memfake.New(kind, clock)}
	late := func(context.Context, actions.Request, actions.Outcome) error { return nil }
	w, err := r.h.buildWiring(o, st, mode, actions.NewDispatcher(), late)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(w.close)
	r.w, r.h.wiring = w, w
	return r
}

func TestChatCapability_OnWithoutDesktop(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	if on, reason := r.h.chatAvailable(); !on {
		t.Fatalf("a relay hub with its runner and no Desktop: off (%s)", reason)
	}
	// A Desktop that went quiet more than 2 minutes ago is no running app.
	if err := r.st.Heartbeat(r.now.Add(-3 * time.Minute)); err != nil {
		t.Fatal(err)
	}
	if on, reason := r.h.chatAvailable(); !on {
		t.Fatalf("an old app's stale heartbeat keeps chat off (%s)", reason)
	}
	// The new app's heartbeat says it honours the lease.
	if err := r.st.HeartbeatChat(r.now.Add(-10*time.Second), true); err != nil {
		t.Fatal(err)
	}
	if on, _ := r.h.chatAvailable(); !on {
		t.Fatal("off beside an app that honours the lease")
	}
	hb := r.h.heartbeat(r.st, "Hub")
	if on, _ := hb.Chat(); !on {
		t.Fatal("the heartbeat's chat capability is off")
	}
}

func TestChatCapability_OffWhileOldDesktopRuns(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	if err := r.st.Heartbeat(r.now.Add(-90 * time.Second)); err != nil { // an app with no chat_lease flag
		t.Fatal(err)
	}
	if on, reason := r.h.chatAvailable(); on || reason != wire.ChatOffDesktopTooOld {
		t.Fatalf("beside an old app: %v %q", on, reason)
	}
	if err := r.st.HeartbeatChat(r.now, true); err != nil { // the new app's beat after the update
		t.Fatal(err)
	}
	if on, _ := r.h.chatAvailable(); !on {
		t.Fatal("still off once the new app heartbeats")
	}
}

func TestChatCapability_OffOffRelayAndUnderPolicy(t *testing.T) {
	ck := newChatRig(t, policy.MobileAllowed, transport.KindCloudKit)
	if on, reason := ck.h.chatAvailable(); on || reason != wire.ChatOffNotRelay {
		t.Fatalf("over CloudKit: %v %q", on, reason)
	}
	wo := newChatRig(t, policy.MobileWorkbenchOnly, transport.KindRelay)
	if on, reason := wo.h.chatAvailable(); on || reason != wire.ChatOffPolicy {
		t.Fatalf("workbench_only: %v %q", on, reason)
	}
	if wo.w.chatTimer != nil {
		t.Error("a chat timer under workbench_only")
	}
	// No chat sources: the handlers get no chat and refuse not_supported
	// (TestChatHandlers_RefuseWhenNotOnRelay pins the nil case).
	if wo.w.set.ChatWatches != nil {
		t.Fatal("chat sources under workbench_only")
	}
}

// TestChatWiring_RequestsCountFromTheRequest: the register's watch ends at
// the request's time plus its length (handoff item 6).
func TestChatWiring_RequestsCountFromTheRequest(t *testing.T) {
	w := sources.NewChatWatches()
	req := chatRequests{w}
	at := time.Unix(1_800_000_000, 0)
	req.WatchFeed(7, "open", at)
	req.WatchFeed(8, "prefetch", at)
	req.RequestPage(7, 40, at)
	req.RequestSearch("pay", at)
	if got := w.ActiveFeeds(at.Add(sources.ChatPrefetchHold - time.Second)); !slices.Equal(got, []int64{7, 8}) {
		t.Fatalf("feeds %v", got)
	}
	if got := w.ActiveFeeds(at.Add(sources.ChatPrefetchHold)); !slices.Equal(got, []int64{7}) {
		t.Fatalf("a prefetch outlived its 2 minutes: %v", got)
	}
	if !w.Open(7, at) || w.Open(8, at) {
		t.Fatal("open/prefetch looking")
	}
	if len(w.Pages.Active(at.Add(sources.ChatRequestHold))) != 0 || len(w.Searches.Active(at.Add(sources.ChatRequestHold-time.Second))) != 1 {
		t.Fatal("page/search holds")
	}
}

func (r *chatRig) publishedChat() bool {
	defer func() { r.published = nil }()
	for _, p := range r.published {
		if slices.Contains(p, hubslices.KindChatFeed) && slices.Contains(p, hubslices.KindChatList) {
			return true
		}
	}
	return false
}

func (r *chatRig) publishedHeartbeat() bool {
	for _, p := range r.published {
		if slices.Contains(p, hubslices.KindHeartbeat) {
			return true
		}
	}
	return false
}

// TestChatTimer_RepublishesTimeOnlyChanges: a watch ending, a lease going
// stale, the grant toggled in the sidecar and the capability changing touch
// no watchtower.db row; the timer republishes them (handoff item 9).
func TestChatTimer_RepublishesTimeOnlyChanges(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	tm := r.w.chatTimer
	if tm == nil {
		t.Fatal("no chat timer")
	}
	tm.check()
	r.published = nil
	tm.check()
	if r.publishedChat() || r.publishedHeartbeat() {
		t.Fatal("published with nothing changed")
	}

	// A feed watch ends.
	r.w.set.ChatWatches.Watch(7, "open", r.now.Add(time.Minute))
	tm.check()
	if !r.publishedChat() {
		t.Fatal("a new watch: no publish")
	}
	r.now = r.now.Add(time.Minute)
	tm.check()
	if !r.publishedChat() {
		t.Fatal("a watch's end: no publish")
	}

	// A lease goes stale.
	res, err := r.d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	if err != nil {
		t.Fatal(err)
	}
	conv, _ := res.LastInsertId()
	ms := r.now.UnixMilli()
	if _, err := r.d.Exec(`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms)
		VALUES (?, 'desktop', 'app', 'T', ?, ?)`, conv, ms, ms); err != nil {
		t.Fatal(err)
	}
	tm.check()
	r.published = nil
	r.now = r.now.Add(61 * time.Second)
	tm.check()
	if !r.publishedChat() {
		t.Fatal("a lease gone stale: no publish")
	}

	// A phone gets the chat grant (a sidecar write).
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: "BBBBBBBB-0000-4000-8000-000000000002", Name: "p", Scope: "private", LinkedAt: r.now})
	}); err != nil {
		t.Fatal(err)
	}
	r.published = nil
	tm.check()
	if !r.publishedChat() {
		t.Fatal("a grant toggled in the sidecar: no publish")
	}

	// The capability changes: an old app starts heartbeating.
	if err := r.st.Heartbeat(r.now); err != nil {
		t.Fatal(err)
	}
	tm.check()
	if !r.publishedHeartbeat() {
		t.Fatal("the capability turned off: no heartbeat publish")
	}
}

// TestControlHeartbeatKeepsTheChatLeaseFlag: the Desktop's
// desktop_heartbeat over the control socket carries "chat_lease": 1 (T8);
// the hub keeps the latest beat's flag with its time.
func TestControlHeartbeatKeepsTheChatLeaseFlag(t *testing.T) {
	r := newViewRig(t)
	var req ControlRequest
	if err := json.Unmarshal([]byte(`{"op":"desktop_heartbeat","chat_lease":1}`), &req); err != nil || req.ChatLease != 1 {
		t.Fatalf("decode %+v %v", req, err)
	}
	if a := r.s.handle(req, nil); !a.OK {
		t.Fatalf("answer %+v", a)
	}
	if old, err := r.s.st.OldDesktopRuns(r.clock()); err != nil || old {
		t.Fatalf("after a beat with the flag: old %v %v", old, err)
	}
	if a := r.s.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil); !a.OK {
		t.Fatalf("answer %+v", a)
	}
	if old, err := r.s.st.OldDesktopRuns(r.clock()); err != nil || !old {
		t.Fatalf("after an old app's beat: old %v %v", old, err)
	}
}

// TestChatWiring_TitleHookAndPreferredProvider: the hub's chat store names
// a phone-started chat after its first complete answer (off the turn's
// goroutine, `chat title`'s code) and routes an automatic chat to the
// preferred provider the Mac's automatic routing reads (handoff item 11).
func TestChatWiring_TitleHookAndPreferredProvider(t *testing.T) {
	titled := make(chan int64, 1)
	r := newChatRigWith(t, policy.MobileAllowed, transport.KindRelay, func(o *Options) {
		o.ChatPreferredProvider = "codex"
		o.ChatTitle = func(_ context.Context, conv int64) error { titled <- conv; return nil }
	})
	conv, err := r.w.chatStore.NewConversation(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	st, err := r.w.chatStore.Start(context.Background(), chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if !st.Routing.Automatic || st.Routing.Provider != "codex" {
		t.Fatalf("routing %+v", st.Routing)
	}
	if err := r.w.chatStore.Turn(st).Finalize(chatstore.StatusComplete, nil); err != nil {
		t.Fatal(err)
	}
	r.w.titles.Wait()
	select {
	case got := <-titled:
		if got != conv {
			t.Fatalf("titled chat %d", got)
		}
	default:
		t.Fatal("no AI title after the first complete answer")
	}
}
