package hub

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/chatrun"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/policy"
)

// TestRuntime_ChatrunSweepsBeforeHandlersAndClosesOnStop: building the
// wiring makes the chat runner and runs its sweep before the handlers can
// claim — this hub's lease of an earlier run is released, its reply marked
// session_lost, another owner's lease kept — and the wiring's close (the
// hub's stop, before the daemon closes the database) closes the runner.
func TestRuntime_ChatrunSweepsBeforeHandlersAndClosesOnStop(t *testing.T) {
	d, _ := fileDB(t)
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	newConv := func() int64 {
		res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
		if err != nil {
			t.Fatal(err)
		}
		n, _ := res.LastInsertId()
		return n
	}
	mine, mac := newConv(), newConv()
	start := func(owner db.ChatLeaseOwner, ownerID string, conv int64) chatstore.Started {
		s, err := chatstore.New(d, owner, ownerID).Start(context.Background(),
			chatstore.StartRequest{ConversationID: conv, Mode: chatstore.ModeSend, Text: "hello"})
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	sMine := start(db.ChatLeaseHub, kr.HubIDText(), mine)
	start(db.ChatLeaseDesktop, "app-1", mac)

	o := Options{DB: d, Clock: time.Now, Dir: t.TempDir(), RecordingsDir: t.TempDir()}
	h := &hubRuntime{sup: &supervisor{o: o}, st: st, kr: kr}
	late := func(context.Context, actions.Request, actions.Outcome) error { return nil }
	w, err := h.buildWiring(o, st, policy.MobileAllowed, actions.NewDispatcher(), late)
	if err != nil {
		t.Fatal(err)
	}
	if w.chat == nil {
		w.close()
		t.Fatal("no chat runner on a hub with a database file")
	}
	if l, _ := d.GetChatLease(mine); l != nil {
		t.Errorf("this hub's lease of an earlier run survived the start: %+v", l)
	}
	if l, _ := d.GetChatLease(mac); l == nil {
		t.Error("the Mac's lease was released")
	}
	var code sql.NullString
	if err := d.QueryRow(`SELECT error_code FROM chat_messages WHERE id = ?`, sMine.AssistantMessageID).Scan(&code); err != nil {
		t.Fatal(err)
	}
	if code.String != "session_lost" {
		t.Errorf("the cut reply's error code = %q, want session_lost", code.String)
	}

	w.close()
	_, err = w.chat.Run(context.Background(), chatstore.StartRequest{ConversationID: mine, Mode: chatstore.ModeSend, Text: "x"})
	if !errors.Is(err, chatrun.ErrClosed) {
		t.Errorf("Run after the hub stopped = %v, want ErrClosed", err)
	}
}

// TestRuntime_ChatrunInertWithoutDatabaseFile: an in-memory database (no
// file for a session's --db-path) leaves the hub without a chat runner.
func TestRuntime_ChatrunInertWithoutDatabaseFile(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	h := &hubRuntime{kr: kr}
	if r := h.newChatRunner(Options{DB: d, Dir: t.TempDir()}, nil, func(func()) bool { return true }); r != nil {
		t.Error("a chat runner over a database with no file")
	}
}
