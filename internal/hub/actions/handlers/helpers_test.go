package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// TestMain installs the db schema template cache: every db.Open(":memory:")
// would otherwise run the whole goose suite.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// fakePort is a session-host with scripted answers that records every line.
type fakePort struct {
	mu        sync.Mutex
	live      map[int64]LiveRun
	result    DeliverResult
	err       error
	delivered []DeliverRequest
	checks    []CheckAnswer
	// onDeliver, when set, runs inside Deliver before it answers.
	onDeliver func(DeliverRequest)
}

func newFakePort() *fakePort {
	return &fakePort{live: map[int64]LiveRun{}, result: DeliverResult{Outcome: DeliverSubmitted}}
}

func (p *fakePort) start(sessionID int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.live[sessionID] = LiveRun{SessionID: sessionID, Run: 1, Agent: "claude", StartedAt: time.Now().Add(-time.Minute)}
}

func (p *fakePort) Live(_ context.Context, id int64) (LiveRun, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	l, ok := p.live[id]
	return l, ok, nil
}

func (p *fakePort) Deliver(ctx context.Context, r DeliverRequest) (DeliverResult, error) {
	if p.onDeliver != nil {
		p.onDeliver(r)
	}
	check := r.Check(ctx)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.delivered = append(p.delivered, r)
	p.checks = append(p.checks, check)
	return p.result, p.err
}

func (p *fakePort) Interrupt(context.Context, int64, uint64) error { return nil }
func (p *fakePort) Start(context.Context, StartRequest) (StartResult, error) {
	return StartResult{}, nil
}
func (p *fakePort) Stop(context.Context, int64) error { return nil }

func (p *fakePort) lines() []DeliverRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]DeliverRequest(nil), p.delivered...)
}

type env struct {
	t       *testing.T
	db      *db.DB
	store   *state.Store
	port    *fakePort
	h       *Handlers
	disp    *actions.Dispatcher
	desktop bool
	clip    []string
	woken   int
	device  secure.ID
	seq     int
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), disp: actions.NewDispatcher()}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e.store = st
	e.device = secure.ID{0x0a, 0x0b}
	e.h = Register(e.disp, Deps{
		DB: e.db, Store: st, Sessions: e.port,
		DesktopHost:     func() bool { return e.desktop },
		Clipboard:       func(s string) error { e.clip = append(e.clip, s); return nil },
		WakeAutomations: func() { e.woken++ },
	})
	return e
}

// linkDevice links the env's phone with the given grants.
func (e *env) linkDevice(typing, startAllowed, startGranted bool) {
	e.t.Helper()
	err := e.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: e.device.String(), Name: "phone", Scope: "private", LinkedAt: time.Now(),
			TypingAllowed: typing, StartSessionsAllowed: startAllowed, StartSessionsGranted: startGranted,
		})
	})
	if err != nil {
		e.t.Fatal(err)
	}
}

// request builds an action; params values are JSON-encoded.
func (e *env) request(kind string, entity *int64, params map[string]any) actions.Request {
	e.t.Helper()
	e.seq++
	raw := map[string]json.RawMessage{}
	for k, v := range params {
		b, err := json.Marshal(v)
		if err != nil {
			e.t.Fatal(err)
		}
		raw[k] = b
	}
	a := wire.ActionRequest{ID: "act-" + strconv.Itoa(e.seq), Kind: kind, Params: raw, Status: wire.StatusPending}
	if entity != nil {
		s := strconv.FormatInt(*entity, 10)
		a.EntityID = &s
	}
	return actions.Request{
		Device: e.device, RecordName: fmt.Sprintf("a-%s-%d", e.device, e.seq), Action: a, ReceivedAt: time.Now(),
	}
}

func id(v int64) *int64 { return &v }

func (e *env) exec(q string, args ...any) {
	e.t.Helper()
	if _, err := e.db.Exec(q, args...); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) workbench() int64 {
	e.t.Helper()
	wb, err := e.db.CreateWorkbench("acme", e.t.TempDir())
	if err != nil {
		e.t.Fatal(err)
	}
	return wb
}

func (e *env) session(wb int64) int64 {
	e.t.Helper()
	res, err := e.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'zsh', '/tmp/acme')`, wb)
	if err != nil {
		e.t.Fatal(err)
	}
	sid, _ := res.LastInsertId()
	return sid
}

func (e *env) ask(a db.OwnerAsk) int64 {
	e.t.Helper()
	if a.Title == "" {
		a.Title = "Flag?"
	}
	var askID int64
	err := e.db.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = e.db.InsertOwnerAsk(tx, a)
		return err
	})
	if err != nil {
		e.t.Fatal(err)
	}
	return askID
}

func (e *env) scalar(q string, args ...any) string {
	e.t.Helper()
	var v sql.NullString
	if err := e.db.QueryRow(q, args...).Scan(&v); err != nil {
		e.t.Fatal(err)
	}
	return v.String
}

func (e *env) count(q string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.QueryRow(q, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func wantOutcome(t *testing.T, got actions.Outcome, status, reason string) {
	t.Helper()
	if got.Status != status || got.Reason != reason {
		t.Fatalf("outcome = %+v, want %s/%s", got, status, reason)
	}
}
