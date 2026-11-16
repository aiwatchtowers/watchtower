package hub

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/chatengine"
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
	o := Options{DB: r.d, Clock: clock, Dir: t.TempDir(), RecordingsDir: t.TempDir(), ChatEngine: testChatEngine(t, r.d),
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
		t.Fatalf("a relay hub with the engine and no Desktop: off (%s)", reason)
	}
	hb := r.h.heartbeat(r.st, "Hub")
	if on, _ := hb.Chat(); !on {
		t.Fatal("the heartbeat's chat capability is off")
	}
}

// TestChatCapability_NoDesktopTooOld: a running Desktop app, of any
// version, no longer turns chat off — every turn runs on the daemon's one
// engine (unified chat §6.4); an older app's heartbeat (no chat_lease flag)
// leaves chat on.
func TestChatCapability_NoDesktopTooOld(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	if err := r.st.Heartbeat(r.now.Add(-10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if on, reason := r.h.chatAvailable(); !on {
		t.Fatalf("beside a running app: off (%s)", reason)
	}
}

// TestChatWiring_UsesDaemonEngine: the hub builds no engine of its own: the
// handlers and the sources use Options.ChatEngine, and a turn started
// through the phone's chat_turn runs on it (its live turn is that engine's).
func TestChatWiring_UsesDaemonEngine(t *testing.T) {
	var eng *chatengine.Engine
	r := newChatRigWith(t, policy.MobileAllowed, transport.KindRelay, func(o *Options) { eng = o.ChatEngine })
	if r.w.chat != eng {
		t.Fatal("the hub does not use the daemon's engine")
	}
	deps := r.h.chatDeps(r.h.sup.o, r.w, "")
	if got, ok := deps.Engine.(*chatengine.Engine); !ok || got != eng {
		t.Fatalf("the handlers' engine is %T, not the daemon's", deps.Engine)
	}
	conv, err := eng.NewConversation(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	st, err := deps.Engine.Turn(context.Background(), chatengine.TurnRequest{StartRequest: chatstore.StartRequest{
		ConversationID: conv, Mode: chatstore.ModeSend, Text: "hello"}})
	if err != nil {
		t.Fatal(err)
	}
	var owner, ownerID string
	if err := r.d.QueryRow(`SELECT owner, owner_id FROM chat_turn_leases WHERE conversation_id = ? AND turn_id = ?`,
		conv, st.TurnID).Scan(&owner, &ownerID); err != nil {
		t.Fatalf("no lease of the turn: %v", err)
	}
	if ownerID != chatengine.LeaseOwnerID {
		t.Fatalf("the turn's lease is %s/%s, not the engine's", owner, ownerID)
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

	// The capability changes (the transport switches off the relay).
	tm.available = func() (bool, string) { return false, wire.ChatOffNotRelay }
	tm.check()
	if !r.publishedHeartbeat() {
		t.Fatal("the capability turned off: no heartbeat publish")
	}
}

// TestControlHeartbeatAcceptsTheOldChatLeaseFlag: an app's
// desktop_heartbeat with "chat_lease" (the field of the iPhone chat's
// lease era) is accepted and ignored for one release: the beat is kept.
func TestControlHeartbeatAcceptsTheOldChatLeaseFlag(t *testing.T) {
	r := newViewRig(t)
	var req ControlRequest
	if err := json.Unmarshal([]byte(`{"op":"desktop_heartbeat","chat_lease":1}`), &req); err != nil {
		t.Fatalf("decode %+v %v", req, err)
	}
	if a := r.s.handle(req, nil); !a.OK {
		t.Fatalf("answer %+v", a)
	}
	if fresh, seen, err := r.s.st.DesktopHost(r.clock()); err != nil || !fresh || !seen {
		t.Fatalf("the beat was not kept: %v %v %v", fresh, seen, err)
	}
}

// TestChatWiring_CloseRacesSpawns: background work (a turn end's push, an
// apply) spawned while the hub closes never misuses the WaitGroup (run
// under -race), and once close returned nothing starts.
func TestChatWiring_CloseRacesSpawns(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.w.spawn(func() {})
		}()
	}
	r.w.close()
	wg.Wait()
	r.w.bg.Wait()
	if r.w.spawn(func() {}) {
		t.Fatal("background work starts after the close")
	}
}

// TestChatWiring_CloseWaitsForAnApply: the hub's stop waits for an approved
// action's apply already running (it is never cut by the database closing
// under it), and refuses to start one after.
func TestChatWiring_CloseWaitsForAnApply(t *testing.T) {
	r := newChatRig(t, policy.MobileAllowed, transport.KindRelay)
	release := make(chan struct{})
	var done atomic.Bool
	if !r.w.spawn(func() { <-release; done.Store(true) }) {
		t.Fatal("spawn refused on a running hub")
	}
	closed := make(chan struct{})
	go func() {
		r.w.close()
		close(closed)
	}()
	close(release)
	<-closed
	if !done.Load() {
		t.Fatal("the close returned before the apply ended")
	}
	if r.w.spawn(func() { t.Error("ran after the close") }) {
		t.Fatal("spawn accepted work after the close")
	}
}
