package askanswer

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/sessionstate"
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

const questions = `{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}`

// fakePort is a session-host with scripted answers that records every line.
type fakePort struct {
	mu        sync.Mutex
	live      map[int64]LiveRun
	liveErr   error
	result    DeliverResult
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
	if p.liveErr != nil {
		return LiveRun{}, false, p.liveErr
	}
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
	return p.result, nil
}

func (p *fakePort) lines() []DeliverRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]DeliverRequest(nil), p.delivered...)
}

// memHeld is a HeldStore in memory (the hub's is hub_meta).
type memHeld struct {
	mu sync.Mutex
	kv map[string]string
}

func (m *memHeld) Meta(key string) (string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.kv[key]
	return v, ok, nil
}

func (m *memHeld) SetMeta(key, value string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.kv[key] = value
	return nil
}

func (m *memHeld) raw() string {
	v, _, _ := m.Meta(HeldMetaKey)
	return v
}

type env struct {
	t    *testing.T
	db   *db.DB
	port *fakePort
	held *memHeld
	a    *Answerer
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), held: &memHeld{kv: map[string]string{}}}
	e.a = e.restart()
	return e
}

// restart is a new Answerer over the same database, port and held store.
func (e *env) restart() *Answerer {
	return New(Deps{DB: e.db, Sessions: e.port, Held: e.held})
}

func (e *env) exec(q string, args ...any) {
	e.t.Helper()
	if _, err := e.db.Exec(q, args...); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) scalar(q string, args ...any) string {
	e.t.Helper()
	var v sql.NullString
	if err := e.db.QueryRow(q, args...).Scan(&v); err != nil {
		e.t.Fatal(err)
	}
	return v.String
}

type seeded struct{ wb, session, ask int64 }

// seedAsk is a workbench with one session row and one open question filed
// from it.
func (e *env) seedAsk() seeded {
	e.t.Helper()
	wb, err := e.db.CreateWorkbench("acme", e.t.TempDir())
	if err != nil {
		e.t.Fatal(err)
	}
	res, err := e.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'zsh', '/tmp/acme')`, wb)
	if err != nil {
		e.t.Fatal(err)
	}
	sid, _ := res.LastInsertId()
	var askID int64
	err = e.db.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = e.db.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true}, Kind: asks.KindQuestion,
			Title: "Flag?", Payload: questions,
		})
		return err
	})
	if err != nil {
		e.t.Fatal(err)
	}
	return seeded{wb, sid, askID}
}

// hooksReport marks the session's hooks as reporting this run with state.
func (e *env) hooksReport(sid int64, agentState string) {
	e.exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?`,
		agentState, db.AgentStateStamp(time.Now()), sid)
}

func (e *env) askRow(id int64) *db.OwnerAsk {
	e.t.Helper()
	a, err := e.db.GetOwnerAskByID(id)
	if err != nil {
		e.t.Fatal(err)
	}
	return a
}

func yesAnswer() asks.Answer {
	return asks.Answer{
		Answers:   []asks.QuestionAnswer{{ID: "a", Labels: []string{"Yes"}}},
		Checklist: []asks.CheckAnswer{}, Comments: []asks.Comment{},
	}
}

// answer answers s's ask with yes through a.
func (e *env) answer(a *Answerer, s seeded) Result {
	e.t.Helper()
	r, err := a.Answer(context.Background(), AnswerRequest{Ask: e.askRow(s.ask), Answer: yesAnswer()})
	if err != nil {
		e.t.Fatal(err)
	}
	return r
}

func wantDelivery(t *testing.T, got Result, delivery string) {
	t.Helper()
	if !got.Stored || got.Delivery != delivery {
		t.Fatalf("result = %+v, want stored with delivery %q", got, delivery)
	}
}

func heldCount(a *Answerer) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.held)
}

// MARK: - The answer's write (WATCHMAN-02)

// The owner answered on the Mac first: the twin's answer loses the
// compare-and-set, writes nothing, types nothing and runs no Also.
func TestWATCHMAN02_TwinNeverOverwritesOwnerAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "waiting")
	owner := `{"answers":[{"id":"a","labels":["No"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
	ask := e.askRow(s.ask) // read while open, as the twin did
	// OwnerAskQueries.answer, the Desktop's write.
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = '2026-11-18T08:00:00Z'
		WHERE id = ? AND status = 'open'`, owner, s.ask)

	alsoRan := false
	got, err := e.a.Answer(context.Background(), AnswerRequest{Ask: ask, Answer: yesAnswer(),
		Also: func(*sql.Tx) error { alsoRan = true; return nil }})

	if err != nil || got.Stored || got.Delivery != "" {
		t.Fatalf("result = %+v err = %v, want not stored", got, err)
	}
	if a := e.scalar(`SELECT answer FROM owner_asks WHERE id = ?`, s.ask); a != owner {
		t.Fatalf("answer = %q, want the owner's", a)
	}
	if len(e.port.lines()) != 0 {
		t.Fatal("the loser types nothing")
	}
	if alsoRan {
		t.Fatal("Also runs only for the winner")
	}
}

func TestAnswerer_MarksOnlyByWinner(t *testing.T) {
	e := newEnv(t)
	marks := []db.SpecReviewMark{{ItemKey: "bs:1", State: "comment", Body: "add one", About: "Threads"}}
	countMarks := func(ask int64) string {
		return e.scalar(`SELECT COUNT(*) FROM spec_review_marks WHERE ask_id = ?`, ask)
	}

	// A loser writes no marks.
	lost := e.seedAsk()
	ask := e.askRow(lost.ask)
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, lost.ask)
	if got, err := e.a.Answer(context.Background(), AnswerRequest{Ask: ask, Answer: yesAnswer(), Marks: marks}); err != nil || got.Stored {
		t.Fatalf("result = %+v err = %v", got, err)
	}
	if n := countMarks(lost.ask); n != "0" {
		t.Fatalf("loser marks = %s", n)
	}

	// An Also that fails rolls back the answer and the marks.
	failing := e.seedAsk()
	got, err := e.a.Answer(context.Background(), AnswerRequest{Ask: e.askRow(failing.ask), Answer: yesAnswer(), Marks: marks,
		Also: func(*sql.Tx) error { return errors.New("outcome not written") }})
	if err == nil || got.Stored {
		t.Fatalf("result = %+v err = %v, want the Also's error", got, err)
	}
	if st := e.scalar(`SELECT status FROM owner_asks WHERE id = ?`, failing.ask); st != "open" || countMarks(failing.ask) != "0" {
		t.Fatalf("status = %s marks = %s, want open and none", st, countMarks(failing.ask))
	}

	// A winner writes them with its answer, Also in the same transaction.
	won := e.seedAsk()
	var marksInAlso string
	got, err = e.a.Answer(context.Background(), AnswerRequest{Ask: e.askRow(won.ask), Answer: yesAnswer(), Marks: marks,
		Also: func(tx *sql.Tx) error {
			return tx.QueryRow(`SELECT state || ':' || body FROM spec_review_marks WHERE ask_id = ? AND item_key = 'bs:1'`,
				won.ask).Scan(&marksInAlso)
		}})
	if err != nil || !got.Stored {
		t.Fatalf("result = %+v err = %v", got, err)
	}
	if marksInAlso != "comment:add one" {
		t.Fatalf("mark seen in Also = %q", marksInAlso)
	}
	if about := e.scalar(`SELECT about FROM spec_review_marks WHERE ask_id = ?`, won.ask); about != "Threads" {
		t.Fatalf("about = %q", about)
	}
}

func TestAnswerer_SessionGoneStoresAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()

	wantDelivery(t, e.answer(e.a, s), DeliveryNoSession)
	if st := e.scalar(`SELECT status FROM owner_asks WHERE id = ?`, s.ask); st != "answered" {
		t.Fatalf("status = %s, want answered (the brief delivers it)", st)
	}
}

// Held answers kept by one Answerer are reloaded by a new one over the same
// store and go once each.
func TestAnswerer_HeldLinesReloadAcrossInstances(t *testing.T) {
	e := newEnv(t)
	hub, twin := e.seedAsk(), e.seedAsk()
	for _, s := range []seeded{hub, twin} {
		e.port.start(s.session)
		e.hooksReport(s.session, "approval")
		wantDelivery(t, e.answer(e.a, s), DeliveryHeld)
	}
	for _, s := range []seeded{hub, twin} {
		if !strings.Contains(e.held.raw(), `"ask":`+strconv.FormatInt(s.ask, 10)+",") {
			t.Fatalf("held = %s, want ask %d", e.held.raw(), s.ask)
		}
	}

	restarted := e.restart()
	for _, s := range []seeded{hub, twin} {
		e.hooksReport(s.session, "waiting")
	}
	restarted.DeliverHeld(context.Background())
	restarted.DeliverHeld(context.Background())

	lines := e.port.lines()
	if len(lines) != 2 || lines[0].SessionID == lines[1].SessionID {
		t.Fatalf("lines = %+v, want one per session", lines)
	}
	if heldCount(restarted) != 0 || e.held.raw() != "[]" {
		t.Fatalf("held = %d %s", heldCount(restarted), e.held.raw())
	}
}

// The Mac decided first: the twin's decision writes nothing and decided_by
// stays the Mac's.
func TestAnswerer_ClosePermissionOwnerFirst(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	res, err := e.db.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
		VALUES (?, ?, 'Bash', 'ls', 'pending', ?)`, s.session, s.wb, db.AgentStateStamp(time.Now()))
	if err != nil {
		t.Fatal(err)
	}
	reqID, _ := res.LastInsertId()
	e.exec(`UPDATE permission_requests SET status = 'denied', decided_at = ?, decided_by = 'Mac' WHERE id = ? AND status = 'pending'`,
		db.AgentStateStamp(time.Now()), reqID)

	alsoRan := false
	ok, err := e.a.ClosePermission(context.Background(), PermissionDecision{RequestID: reqID, SessionID: s.session, Allow: true,
		DecidedBy: ByWatchman, Also: func(*sql.Tx) error { alsoRan = true; return nil }})

	if err != nil || ok || alsoRan {
		t.Fatalf("ok = %v err = %v also = %v, want lost", ok, err, alsoRan)
	}
	if by := e.scalar(`SELECT status || ':' || decided_by FROM permission_requests WHERE id = ?`, reqID); by != "denied:Mac" {
		t.Fatalf("row = %s", by)
	}

	// A pending one is the twin's, named so.
	res, err = e.db.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
		VALUES (?, ?, 'Bash', 'ls', 'pending', ?)`, s.session, s.wb, db.AgentStateStamp(time.Now()))
	if err != nil {
		t.Fatal(err)
	}
	next, _ := res.LastInsertId()
	if ok, err := e.a.ClosePermission(context.Background(), PermissionDecision{RequestID: next, SessionID: s.session,
		DecidedBy: ByWatchman}); err != nil || !ok {
		t.Fatalf("ok = %v err = %v", ok, err)
	}
	if by := e.scalar(`SELECT status || ':' || decided_by FROM permission_requests WHERE id = ?`, next); by != "denied:watchman" {
		t.Fatalf("row = %s", by)
	}
}

// A line of no ask goes as an answer's does, and when held never outlives
// its Answerer (nothing of it is kept in the store).
// SubmitLineNow (the stall ping) asks the host to hold rather than paste
// beside a draft, and never keeps a line for later: a prompt, a draft or a
// session gone send nothing and queue nothing (DeliverHeld types nothing).
func TestAnswerer_SubmitLineNowNeverQueues(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, s.ask) // the stall ping goes only with no open ask
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	if got := e.a.SubmitLineNow(context.Background(), s.session, e.stopOf(s.session), "ping"); got != DeliveryHeld {
		t.Fatalf("into a permission prompt: %q", got)
	}
	if n := len(e.port.lines()); n != 0 {
		t.Fatalf("typed into a permission prompt (%d)", n)
	}
	e.hooksReport(s.session, "waiting")
	stop := e.stopOf(s.session)
	e.port.result = DeliverResult{Outcome: DeliverHeld, Reason: "prompt_has_text"}
	if got := e.a.SubmitLineNow(context.Background(), s.session, stop, "ping"); got != DeliveryHeld {
		t.Fatalf("beside a draft: %q", got)
	}
	lines := e.port.lines()
	if len(lines) != 1 || !lines[0].HoldIfPromptText {
		t.Fatalf("lines = %+v, want one asking the host to hold beside a draft", lines)
	}
	e.port.result = DeliverResult{Outcome: DeliverSubmitted}
	e.a.DeliverHeld(context.Background())
	if n := len(e.port.lines()); n != 1 {
		t.Fatalf("a held line was queued and sent later (%d)", n)
	}
	if got := e.a.SubmitLineNow(context.Background(), s.session, stop, "ping"); got != DeliverySubmitted {
		t.Fatalf("delivery = %q", got)
	}
	if got := e.a.SubmitLineNow(context.Background(), 9999, stop, "ping"); got != DeliveryNoSession {
		t.Fatalf("no session: %q", got)
	}
}

// stopOf is the session's current stop as the stall watch reads it.
func (e *env) stopOf(sid int64) time.Time {
	e.t.Helper()
	e.port.mu.Lock()
	live := e.port.live[sid]
	e.port.mu.Unlock()
	_, row, fresh := ReadState(context.Background(), e.db, sid, live, time.Now())
	at, ok := sessionstate.StoppedSince(row)
	if !fresh || !ok {
		e.t.Fatalf("no stop read for session %d", sid)
	}
	return at
}

// C1: the stall ping goes only into the stop the caller saw. An agent that
// went on, stopped again or asked since gets nothing typed; one that went
// on during the pause after the paste gets no Return (the check refuses
// it) and the caller counts nothing (DeliveryHeld).
func TestAnswerer_SubmitLineNowOnlyIntoTheSameStop(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, s.ask)
	e.port.start(s.session)
	at := time.Now().Add(-10 * time.Second)
	e.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`, db.AgentStateStamp(at), s.session)
	stop := e.stopOf(s.session)
	ctx := context.Background()

	e.exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(at.Add(time.Second)), s.session)
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliveryHeld {
		t.Fatalf("into a working agent: %q", got)
	}
	e.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(at.Add(2*time.Second)), s.session)
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliveryHeld {
		t.Fatalf("into a later stop: %q", got)
	}
	if n := len(e.port.lines()); n != 0 {
		t.Fatalf("typed %d lines into a session that moved on", n)
	}

	stop = e.stopOf(s.session)
	e.exec(`UPDATE owner_asks SET status = 'open', answer = '' WHERE id = ?`, s.ask)
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliveryHeld {
		t.Fatalf("beside an open ask: %q", got)
	}
	if n := len(e.port.lines()); n != 0 {
		t.Fatalf("typed %d lines beside an open ask", n)
	}
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, s.ask)

	// The agent goes on between the paste and the Return: the host leaves
	// the line typed (its re-check refused the Return); it counts as typed,
	// so the stall watch's stuck park can surface it.
	e.port.onDeliver = func(DeliverRequest) {
		e.exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
			db.AgentStateStamp(at.Add(3*time.Second)), s.session)
	}
	e.port.result = DeliverResult{Outcome: DeliverTyped, Reason: "cannot_submit"}
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliveryTyped {
		t.Fatalf("went on during the pause: %q, want typed (left in the prompt)", got)
	}
	e.port.mu.Lock()
	checks := append([]CheckAnswer(nil), e.port.checks...)
	e.port.mu.Unlock()
	if len(checks) != 1 || !checks[0].Fresh || checks[0].CanSubmit {
		t.Fatalf("checks = %+v, want one fresh refusing the Return", checks)
	}

	// The re-check cannot read the state (the row is being deleted): no
	// Return, the line left typed.
	e.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(at.Add(3*time.Second)), s.session)
	stop = e.stopOf(s.session)
	e.port.onDeliver = func(DeliverRequest) {
		e.exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, db.AgentStateStamp(at), s.session)
	}
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliveryTyped {
		t.Fatalf("unread re-check: %q, want typed", got)
	}
	e.port.mu.Lock()
	unread := e.port.checks[len(e.port.checks)-1]
	e.port.mu.Unlock()
	if unread.Fresh || unread.CanSubmit {
		t.Fatalf("check = %+v, want an unread one refusing the Return", unread)
	}
	e.exec(`UPDATE terminal_sessions SET delete_requested_at = NULL WHERE id = ?`, s.session)

	// Still the same stop through the pause: the Return goes.
	e.port.onDeliver = nil
	e.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(at.Add(4*time.Second)), s.session)
	stop = e.stopOf(s.session)
	e.port.result = DeliverResult{Outcome: DeliverSubmitted}
	if got := e.a.SubmitLineNow(ctx, s.session, stop, "ping"); got != DeliverySubmitted {
		t.Fatalf("same stop: %q", got)
	}
	e.port.mu.Lock()
	last := e.port.checks[len(e.port.checks)-1]
	e.port.mu.Unlock()
	if !last.CanSubmit {
		t.Fatalf("check = %+v, want the Return allowed", last)
	}
}

func TestAnswerer_DeliverLineHeldInMemoryOnly(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")

	if got := e.a.DeliverLine(context.Background(), s.session, "Round 2 is ready"); got != DeliveryHeld {
		t.Fatalf("delivery = %q", got)
	}
	if raw := e.held.raw(); raw != "[]" {
		t.Fatalf("held store = %s, want nothing kept", raw)
	}
	e.hooksReport(s.session, "waiting")
	e.a.DeliverHeld(context.Background())
	if lines := e.port.lines(); len(lines) != 1 || lines[0].Text != "Round 2 is ready" {
		t.Fatalf("lines = %+v", lines)
	}
}

// The hub's hooks hear a submitted line and answer a no_paste_mode one.
func TestAnswerer_HooksHearSubmitAndNoPasteMode(t *testing.T) {
	e := newEnv(t)
	var submitted []int64
	e.a.SetHooks(Hooks{
		Submitted:   func(sid int64, _ time.Time) { submitted = append(submitted, sid) },
		NoPasteMode: func(string) string { return "copied" },
	})
	s := e.seedAsk()
	e.port.start(s.session)
	wantDelivery(t, e.answer(e.a, s), DeliverySubmitted)
	if len(submitted) != 1 || submitted[0] != s.session {
		t.Fatalf("submitted = %v", submitted)
	}
	e.port.result = DeliverResult{Outcome: DeliverNoPasteMode}
	if got := e.a.DeliverLine(context.Background(), s.session, "x"); got != "copied" {
		t.Fatalf("delivery = %q", got)
	}
	e.a.SetHooks(Hooks{})
	if got := e.a.DeliverLine(context.Background(), s.session, "x"); got != DeliveryCannotType {
		t.Fatalf("no hook: delivery = %q", got)
	}
}

// A release clears the hooks only while they are still its own: a stopped
// hub never clears the hooks of the hub that started after it.
func TestAnswerer_ReleaseClearsOnlyItsOwnHooks(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverNoPasteMode}
	releaseOld := e.a.SetHooks(Hooks{NoPasteMode: func(string) string { return "old" }})
	releaseNew := e.a.SetHooks(Hooks{NoPasteMode: func(string) string { return "new" }})

	releaseOld()
	if got := e.a.DeliverLine(context.Background(), s.session, "x"); got != "new" {
		t.Fatalf("after the old release: delivery = %q, want the new hub's hook", got)
	}
	releaseNew()
	if got := e.a.DeliverLine(context.Background(), s.session, "x"); got != DeliveryCannotType {
		t.Fatalf("after its own release: delivery = %q", got)
	}
}

// Deps.HeldKey keeps a second Answerer's held answers apart from the hub's
// in the same store.
func TestAnswerer_HeldKeyKeepsLedgersApart(t *testing.T) {
	e := newEnv(t)
	own := New(Deps{DB: e.db, Sessions: e.port, Held: e.held, HeldKey: "watchman_held_asks"})
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	wantDelivery(t, e.answer(own, s), DeliveryHeld)

	if raw, _, _ := e.held.Meta("watchman_held_asks"); !strings.Contains(raw, `"ask":`+strconv.FormatInt(s.ask, 10)+",") {
		t.Fatalf("own key = %q", raw)
	}
	if _, ok, _ := e.held.Meta(HeldMetaKey); ok {
		t.Fatal("the hub's key is untouched")
	}
	if heldCount(e.restart()) != 0 {
		t.Fatal("an Answerer on the hub's key does not reload the other ledger")
	}
}

// The write is not cancelled by the caller's context: an answer whose
// caller gave up (the hub's outcome_unknown) still lands, as before the move.
func TestAnswerer_CancelledContextStillStoresAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	got, err := e.a.Answer(ctx, AnswerRequest{Ask: e.askRow(s.ask), Answer: yesAnswer(),
		Marks: []db.SpecReviewMark{{ItemKey: "k", State: "ok"}}})

	if err != nil || !got.Stored {
		t.Fatalf("result = %+v err = %v, want stored", got, err)
	}
	if st := e.scalar(`SELECT status FROM owner_asks WHERE id = ?`, s.ask); st != "answered" {
		t.Fatalf("status = %s", st)
	}
}

// MARK: - Moved from the hub's ask_test.go (same names)

// PROJ-12 (controller ruling, Swift parity): an answer line is one line with
// the SubmitSettle pause and no kept line breaks or format characters, sent
// without HoldIfPromptText — over the owner's draft the host pastes it and
// leaves it typed.
func TestAnAnswerLineIsTypedBesideTheOwnersDraft(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverTyped}
	wantDelivery(t, e.answer(e.a, s), DeliveryTyped)
	lines := e.port.lines()
	if len(lines) != 1 {
		t.Fatalf("lines = %d", len(lines))
	}
	l := lines[0]
	want := asks.DeliveryLine(s.ask, asks.KindQuestion, asks.Answer{})
	if l.HoldIfPromptText || l.KeepLineBreaks || l.KeepFormat || l.Settle != SubmitSettle || l.Run != 1 || l.Text != want {
		t.Fatalf("request = %+v", l)
	}
}

// The re-check after the pause vouches for a Return only with this run's
// hooks and no permission prompt.
func TestTheRecheckVouchesOnlyForThisRunsHooks(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.answer(e.a, s)
	if c := e.port.checks[0]; !c.Fresh || c.CanSubmit || c.AnswersDialog {
		t.Fatalf("no hook state this run: check = %+v", c)
	}

	s2 := e.seedAsk()
	e.port.start(s2.session)
	e.hooksReport(s2.session, "waiting")
	e.answer(e.a, s2)
	if c := e.port.checks[1]; !c.Fresh || !c.CanSubmit || c.AnswersDialog {
		t.Fatalf("hooks report: check = %+v", c)
	}

	s3 := e.seedAsk()
	e.port.start(s3.session)
	e.hooksReport(s3.session, "waiting")
	e.port.onDeliver = func(DeliverRequest) { e.hooksReport(s3.session, "approval") }
	e.answer(e.a, s3)
	if c := e.port.checks[2]; !c.Fresh || c.CanSubmit || !c.AnswersDialog {
		t.Fatalf("a prompt during the pause: check = %+v", c)
	}
}

// A held answer goes on the next read of the session states once the
// permission prompt is gone, and never into a later launch.
func TestAHeldAnswerGoesOnTheNextStateRead(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	wantDelivery(t, e.answer(e.a, s), DeliveryHeld)

	e.a.DeliverHeld(context.Background())
	if len(e.port.lines()) != 0 || heldCount(e.a) != 1 {
		t.Fatal("still at the prompt: still held, nothing typed")
	}
	e.hooksReport(s.session, "waiting")
	e.a.DeliverHeld(context.Background())
	if len(e.port.lines()) != 1 || heldCount(e.a) != 0 {
		t.Fatalf("lines = %d held = %d, want the line typed once", len(e.port.lines()), heldCount(e.a))
	}

	// A relaunch: the held line is meant for the run before; its brief has it.
	s2 := e.seedAsk()
	e.port.start(s2.session)
	e.hooksReport(s2.session, "approval")
	e.answer(e.a, s2)
	e.port.live[s2.session] = LiveRun{SessionID: s2.session, Run: 2, StartedAt: time.Now()}
	e.hooksReport(s2.session, "waiting")
	e.a.DeliverHeld(context.Background())
	if len(e.port.lines()) != 1 || heldCount(e.a) != 0 {
		t.Fatal("a relaunched session never gets the held line")
	}
}

// A held answer survives a restart (session-host keeps the session): the
// store keeps only its ids, the line comes back from owner_asks.
func TestAHeldAnswerSurvivesAHubRestart(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	wantDelivery(t, e.answer(e.a, s), DeliveryHeld)
	if raw := e.held.raw(); strings.Contains(raw, "answered") || !strings.Contains(raw, `"ask":`) {
		t.Fatalf("held = %q, want ids only", raw)
	}

	restarted := e.restart()
	e.hooksReport(s.session, "waiting")
	restarted.DeliverHeld(context.Background())

	lines := e.port.lines()
	if len(lines) != 1 || lines[0].Text != asks.DeliveryLine(s.ask, asks.KindQuestion, asks.Answer{}) {
		t.Fatalf("lines = %+v", lines)
	}
	if again := e.restart(); heldCount(again) != 0 {
		t.Fatal("a delivered answer is not held again after the next restart")
	}
}

// An answer the brief delivered meanwhile is not rebuilt at start.
func TestAHeldAnswerTheBriefDeliveredIsDropped(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	e.answer(e.a, s)
	e.exec(`UPDATE owner_asks SET status = 'delivered' WHERE id = ?`, s.ask)

	if restarted := e.restart(); heldCount(restarted) != 0 {
		t.Fatal("a delivered answer is not held")
	}
}

// A failed read of the host holds the answer, as a failed state read does.
func TestALiveErrorHoldsTheAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk()
	e.port.start(s.session)
	e.port.liveErr = errors.New("host busy")
	wantDelivery(t, e.answer(e.a, s), DeliveryHeld)
	e.a.DeliverHeld(context.Background())
	if heldCount(e.a) != 1 || len(e.port.lines()) != 0 {
		t.Fatal("still held while the host cannot be read")
	}
	e.port.liveErr = nil
	e.a.DeliverHeld(context.Background())
	if heldCount(e.a) != 0 || len(e.port.lines()) != 1 {
		t.Fatal("goes once the host answers")
	}
}

// N1 (PROJ-12): a line held before its launch was known (the host could not
// be read) never goes into a launch started after the answer was stored —
// that launch's brief already lists it — before or after a restart.
func TestAnUnpinnedHeldLineNeverGoesIntoALaterLaunch(t *testing.T) {
	for _, restart := range []bool{false, true} {
		e := newEnv(t)
		s := e.seedAsk()
		e.port.start(s.session)
		e.port.liveErr = errors.New("host busy")
		wantDelivery(t, e.answer(e.a, s), DeliveryHeld)
		e.port.liveErr = nil
		e.port.live[s.session] = LiveRun{SessionID: s.session, Run: 2, StartedAt: time.Now().Add(2 * time.Second)}
		a := e.a
		if restart {
			a = e.restart()
		}

		a.DeliverHeld(context.Background())

		if len(e.port.lines()) != 0 || heldCount(a) != 0 {
			t.Fatalf("restart=%v: lines = %d held = %d, want the line dropped", restart, len(e.port.lines()), heldCount(a))
		}
	}
}

// N2: each held line leaves the store just before its own delivery, so a
// crash mid-loop loses at most the line in flight.
func TestEachHeldLineLeavesTheStoreJustBeforeItsDelivery(t *testing.T) {
	e := newEnv(t)
	first := e.seedAsk()
	second := e.seedAsk()
	for _, s := range []seeded{first, second} {
		e.port.start(s.session)
		e.hooksReport(s.session, "approval")
		wantDelivery(t, e.answer(e.a, s), DeliveryHeld)
		e.hooksReport(s.session, "waiting")
	}
	var stored []string
	e.port.onDeliver = func(DeliverRequest) { stored = append(stored, e.held.raw()) }

	e.a.DeliverHeld(context.Background())

	if len(stored) != 2 {
		t.Fatalf("deliveries = %d", len(stored))
	}
	ask := func(id int64) string { return `"ask":` + strconv.FormatInt(id, 10) + "," }
	if strings.Contains(stored[0], ask(first.ask)) || !strings.Contains(stored[0], ask(second.ask)) {
		t.Fatalf("during the first delivery held = %s, want only the second ask", stored[0])
	}
	if strings.Contains(stored[1], ask(second.ask)) {
		t.Fatalf("during the second delivery held = %s", stored[1])
	}
}

// N3: a held line goes only while its ask is still answered — not once the
// agent read it (delivered) or it was withdrawn.
func TestAHeldLineOfAnAskNoLongerAnsweredIsSkipped(t *testing.T) {
	for _, status := range []string{"delivered", "withdrawn"} {
		e := newEnv(t)
		s := e.seedAsk()
		e.port.start(s.session)
		e.hooksReport(s.session, "approval")
		e.answer(e.a, s)
		e.hooksReport(s.session, "waiting")
		if status == "withdrawn" {
			e.exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent', answer = '' WHERE id = ?`, s.ask)
		} else {
			e.exec(`UPDATE owner_asks SET status = ? WHERE id = ?`, status, s.ask)
		}

		e.a.DeliverHeld(context.Background())

		if len(e.port.lines()) != 0 || heldCount(e.a) != 0 {
			t.Fatalf("%s: lines = %d held = %d", status, len(e.port.lines()), heldCount(e.a))
		}
	}
}
