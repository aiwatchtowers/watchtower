package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// inboxWorld is one hub (sidecar, processor) over a watchtower.db with the
// real inbox.act, and its linked phone. The dispatcher's inbox_act runs the
// real handler and then, once, stops the hub (a panic out of the pass)
// before the outcome commits: the Mac's restart mid-apply.
type inboxWorld struct {
	t       *testing.T
	ctx     context.Context
	cfg     actions.Config
	phone   *hubtest.Phone
	db      *db.DB
	calls   atomic.Int32 // handler runs
	writes  atomic.Int32 // committed tower writes
	crashed atomic.Bool
	later   []func()
}

func newInboxWorld(t *testing.T, seed ...string) *inboxWorld {
	t.Helper()
	w := &inboxWorld{t: t, ctx: context.Background(), db: db.OpenTestDB(t)}
	for _, s := range seed {
		if _, err := w.db.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ident, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	keys, err := identity.NewKeyring(ident, st, clock)
	if err != nil {
		t.Fatal(err)
	}
	reg := tools.New(w.db)
	if err := reg.Register(approvalTool(t)); err != nil {
		t.Fatal(err)
	}
	var r tower.Registry
	inboxfeed.RegisterAct(&r, inboxfeed.ActDeps{Registry: reg, Background: func(fn func()) { w.later = append(w.later, fn) }})
	tw := tower.New(w.db, tower.Options{Registry: &r, Now: clock, Changed: func([]string) { w.writes.Add(1) }})

	scratch := actions.NewDispatcher()
	h := Register(scratch, Deps{DB: w.db, Store: st, Sessions: newFakePort(), Tower: tw, Clock: clock})
	disp := actions.NewDispatcher()
	disp.Register(inboxActKind, func(ctx context.Context, r actions.Request) actions.Outcome {
		w.calls.Add(1)
		out := h.inboxAct(ctx, r)
		if w.crashed.CompareAndSwap(false, true) {
			panic("the Mac stops before the outcome commits")
		}
		return out
	}, inboxActOptions())

	fake := memfake.New(transport.KindRelay, clock)
	w.cfg = actions.Config{
		Store: st, Transport: fake, Sealer: secure.NewSealer(keys), Opener: secure.NewOpener(keys, keys), Keys: keys,
		Dispatcher: disp, HubRelayID: "hubrelaytest", Clock: clock,
	}
	meta, _ := keys.MetaKey()
	epoch, _ := keys.CurrentEpoch()
	w.phone, err = hubtest.New(hubtest.Config{
		Hub: keys.HubID(), HubKX: ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: "hubrelaytest", Transport: fake, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	dev := w.phone.Device()
	dev.PermissionsAllowed, dev.TypingAllowed = true, true
	if err := st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, dev) }); err != nil {
		t.Fatal(err)
	}
	return w
}

// send writes an inbox_act from the phone carrying req.
func (w *inboxWorld) send(req api.ActRequest) uint64 {
	w.t.Helper()
	b, err := json.Marshal(req)
	if err != nil {
		w.t.Fatal(err)
	}
	a := w.phone.NewAction(inboxActKind)
	if err := json.Unmarshal(b, &a.Params); err != nil {
		w.t.Fatal(err)
	}
	seq, err := w.phone.Queue(a)
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.phone.Send(seq); err != nil {
		w.t.Fatal(err)
	}
	return seq
}

// crashThenRestart runs a pass that stops mid-apply, then passes of a new
// processor on the same sidecar (the restarted Mac) until the phone has its
// final echo of seq.
func (w *inboxWorld) crashThenRestart(seq uint64) wire.ActionRequest {
	w.t.Helper()
	func() {
		defer func() {
			if recover() == nil {
				w.t.Fatal("the pass did not stop mid-apply")
			}
		}()
		_, _ = actions.NewProcessor(w.cfg).Pass(w.ctx)
	}()
	restarted := actions.NewProcessor(w.cfg)
	for range 10 {
		if _, err := restarted.Pass(w.ctx); err != nil {
			w.t.Fatal(err)
		}
		if _, err := w.phone.Sync(); err != nil {
			w.t.Fatal(err)
		}
		if e, ok := w.phone.Echoes[seq]; ok && e.Status != wire.StatusReceived {
			return e
		}
	}
	w.t.Fatal("no final echo after the restart")
	return wire.ActionRequest{}
}

func (w *inboxWorld) count(q string) int {
	w.t.Helper()
	var n int
	if err := w.db.QueryRow(q).Scan(&n); err != nil {
		w.t.Fatal(err)
	}
	return n
}

// TestReplay_InboxActRunsOnceAcrossAMacRestart: a guarded inbox_act whose
// hub stopped after the tower committed is dispatched again after the
// restart (relay_processed holds no begun row for it), and the tower's
// ledger answers the stored result: the write ran once and the phone gets
// applied.
func TestReplay_InboxActRunsOnceAcrossAMacRestart(t *testing.T) {
	w := newInboxWorld(t,
		`INSERT INTO automations (id, slug, scope, path, name, enabled, disabled_reason, origin) VALUES (1, 'notes', 'personal', '/recipes/notes.md', 'Notes', 1, '', 'owner')`,
		`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`,
		`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, priority, created_at, blocks_json, output_key, content_hash, written_at, changed_at)
			VALUES (1, 1, 1, 'inbox', 'Notes', 'body', 'medium', '2026-11-16T09:00:00Z', '', NULL, 'h1', '2026-11-16T09:00:00Z', '2026-11-16T09:00:00Z')`)
	seq := w.send(api.ActRequest{WriteParams: api.WriteParams{RequestID: "00000000-0000-4000-8000-000000000101"},
		Target: "o1", Verb: api.ActDone, Params: api.ActParams{ContentHash: "h1"}})
	echo := w.crashThenRestart(seq)
	if echo.Status != wire.StatusApplied {
		t.Fatalf("echo %s, want applied", echo.Status)
	}
	if n := w.calls.Load(); n != 2 {
		t.Fatalf("handler ran %d times, want 2 (before and after the restart)", n)
	}
	if n := w.writes.Load(); n != 1 {
		t.Fatalf("%d committed writes, want 1: the replay answered the stored result", n)
	}
	if n := w.count(`SELECT COUNT(*) FROM tower_requests WHERE state = 'done'`); n != 1 {
		t.Fatalf("%d done ledger rows", n)
	}
	if n := w.count(`SELECT COUNT(*) FROM automation_outputs WHERE id = 1 AND done_at IS NOT NULL`); n != 1 {
		t.Fatal("the output is not done")
	}
}

// TestInboxAct_HubStopMidApproveAnswersUnknown: an approve is claimed begun
// before its handler; a hub that stops mid-apply leaves it begun, and after
// the restart the phone gets outcome_unknown and nothing runs again.
func TestInboxAct_HubStopMidApproveAnswersUnknown(t *testing.T) {
	w := newInboxWorld(t, `INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at)
		VALUES (1, 'fake', '{"text":"hello"}', 'r', 'pending', '2026-11-16T09:00:00Z')`)
	seq := w.send(api.ActRequest{WriteParams: api.WriteParams{RequestID: "00000000-0000-4000-8000-000000000102"},
		Target: "a1", Verb: api.ActApproval,
		Params: api.ActParams{ApprovalVerb: api.ApprovalApprove, ArgsSHA256: tools.ArgsSHA256(`{"text":"hello"}`)}})
	echo := w.crashThenRestart(seq)
	if echo.Status != wire.StatusFailed || echo.Reason == nil || *echo.Reason != reasonOutcomeUnknown {
		t.Fatalf("echo %s/%v, want failed/outcome_unknown", echo.Status, echo.Reason)
	}
	if n := w.calls.Load(); n != 1 {
		t.Fatalf("handler ran %d times, want 1", n)
	}
	if len(w.later) != 1 {
		t.Fatalf("%d tool runs queued, want 1", len(w.later))
	}
}
