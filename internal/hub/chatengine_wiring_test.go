package hub

import (
	"context"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/chatengine"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// testChatEngine is a started chat engine over d (its sessions would run
// /usr/bin/false: the hub tests start no turn), closed when the test ends —
// the daemon's, not the hub's.
func testChatEngine(t *testing.T, d *db.DB) *chatengine.Engine {
	t.Helper()
	path, err := mainFile(context.Background(), d)
	if err != nil {
		t.Fatal(err)
	}
	e := chatengine.New(chatengine.Config{Exe: "/usr/bin/false", DBPath: path, Dir: t.TempDir(), DB: d})
	if err := e.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.Close(context.Background()) })
	return e
}

// TestRuntime_ChatEngineIsTheDaemons: the hub uses the engine it is given,
// publishes the chat slices on its changes, and at its stop only unhooks it
// — the engine keeps running for chat.sock (the daemon stops it later).
func TestRuntime_ChatEngineIsTheDaemons(t *testing.T) {
	d, _ := fileDB(t)
	eng := testChatEngine(t, d)
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	var mu sync.Mutex
	var published [][]hubslices.Kind
	o := Options{DB: d, Clock: time.Now, Dir: t.TempDir(), RecordingsDir: t.TempDir(), ChatEngine: eng,
		published: func(k []hubslices.Kind) { mu.Lock(); published = append(published, k); mu.Unlock() }}
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	h := &hubRuntime{sup: &supervisor{o: o}, st: st, kr: kr}
	late := func(context.Context, actions.Request, actions.Outcome) error { return nil }
	w, err := h.buildWiring(o, st, policy.MobileAllowed, actions.NewDispatcher(), late)
	if err != nil {
		t.Fatal(err)
	}
	if w.chat != eng {
		w.close()
		t.Fatal("the hub does not use the daemon's engine")
	}
	chatPublished := func() bool {
		mu.Lock()
		defer mu.Unlock()
		return slices.ContainsFunc(published, func(k []hubslices.Kind) bool {
			return slices.Contains(k, hubslices.KindChatFeed) && slices.Contains(k, hubslices.KindChatList)
		})
	}
	if _, err := eng.NewConversation(context.Background(), nil, nil); err != nil {
		t.Fatal(err)
	}
	if !chatPublished() {
		t.Error("an engine change published no chat slices")
	}

	w.close()
	mu.Lock()
	published = nil
	mu.Unlock()
	if _, err := eng.NewConversation(context.Background(), nil, nil); err != nil {
		t.Fatalf("the engine stopped with the hub: %v", err)
	}
	if chatPublished() {
		t.Error("a stopped hub still publishes the engine's changes")
	}
}

// TestRuntime_NoChatEngineIsRunnerDown: a hub given no engine has no chat
// (runner_down).
func TestRuntime_NoChatEngineIsRunnerDown(t *testing.T) {
	r := newChatRigWith(t, policy.MobileAllowed, transport.KindRelay, func(o *Options) { o.ChatEngine = nil })
	if r.w.chat != nil {
		t.Fatal("a chat engine the daemon did not give")
	}
	if on, reason := r.h.chatAvailable(); on || reason != wire.ChatOffRunnerDown {
		t.Fatalf("without an engine: %v %q", on, reason)
	}
}
