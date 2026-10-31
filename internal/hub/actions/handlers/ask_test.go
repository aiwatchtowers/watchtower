package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
)

// Go twins of AskAnswerHandlerTests: the phone's answer through Go's own
// reader, each outcome its echo, one store and one line per action, and the
// handler's own timeout.

const questions = `{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}`

var yes = map[string]any{
	"verdict":   "",
	"answers":   []any{map[string]any{"id": "a", "labels": []string{"Yes"}, "other": ""}},
	"checklist": []any{},
	"comments":  []any{},
	"note":      "",
}

type seeded struct{ wb, session, ask int64 }

// seedAsk is a workbench with one session row and one open ask filed from it.
func (e *env) seedAsk(kind, payload string) seeded {
	e.t.Helper()
	wb := e.workbench()
	sid := e.session(wb)
	docPath := ""
	if kind == asks.KindReview {
		docPath = "docs/spec.md"
	}
	a := e.ask(db.OwnerAsk{
		WorkbenchID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true}, Kind: kind, Payload: payload, DocPath: docPath,
	})
	return seeded{wb, sid, a}
}

// hooksReport marks the session's hooks as reporting this run with state.
func (e *env) hooksReport(sid int64, agentState string) {
	e.exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?`,
		agentState, db.AgentStateStamp(time.Now()), sid)
}

func (e *env) answerAction(s seeded, answer any) actions.Request {
	return e.request("ask_answer", id(s.ask), map[string]any{"workbench_id": s.wb, "answer": answer})
}

func (e *env) stored(askID int64) (status, answer string) {
	e.t.Helper()
	if err := e.db.QueryRow(`SELECT status, answer FROM owner_asks WHERE id = ?`, askID).Scan(&status, &answer); err != nil {
		e.t.Fatal(err)
	}
	return status, answer
}

func wantDelivery(t *testing.T, got actions.Outcome, delivery string) {
	t.Helper()
	if got.Status != wire.StatusApplied || got.Delivery != delivery {
		t.Fatalf("outcome = %+v, want applied with delivery %q", got, delivery)
	}
}

func review(verdict string, comments ...any) map[string]any {
	if comments == nil {
		comments = []any{}
	}
	return map[string]any{"verdict": verdict, "answers": []any{}, "checklist": []any{}, "comments": comments, "note": ""}
}

// MARK: - Exactly once

func TestTheSameActionDeliveredTwiceStoresOnceAndTypesOneLine(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.hooksReport(s.session, "waiting")
	req := e.answerAction(s, yes)

	first := e.h.askAnswer(context.Background(), req)
	_, answeredFirst := e.stored(s.ask)
	second := e.h.askAnswer(context.Background(), req)

	wantDelivery(t, first, deliverySubmitted)
	wantDelivery(t, second, deliverySubmitted) // a re-run is applied again, with the delivery kept
	if _, again := e.stored(s.ask); again != answeredFirst {
		t.Fatalf("answer rewritten: %q → %q", answeredFirst, again)
	}
	if n := len(e.port.lines()); n != 1 {
		t.Fatalf("lines delivered = %d, want 1", n)
	}
}

// The answer is stored and typed, then its echo's save fails: the processor
// runs the (idempotent) kind again — applied with the kept delivery, no second
// line. (The relay-level halves of testTheSameRecordRelayedTwice… are the
// processor's exactly-once tests, Plan 1a Task 9.)
func TestARerunAfterAFailedEchoSaveIsAppliedWithTheKeptDelivery(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverTyped}
	req := e.answerAction(s, yes)

	wantDelivery(t, e.h.askAnswer(context.Background(), req), deliveryTyped)
	if st, _ := e.stored(s.ask); st != "answered" {
		t.Fatalf("status = %s, want answered before the echo", st)
	}
	wantDelivery(t, e.h.askAnswer(context.Background(), req), deliveryTyped)
	if n := len(e.port.lines()); n != 1 {
		t.Fatalf("lines delivered = %d, want 1", n)
	}
}

// The same answer already stored with no delivery kept for this action (the
// hub stopped before keeping it): applied, the delivery left out, nothing
// written or typed again.
func TestARerunWithNoKeptDeliveryIsAppliedWithoutOne(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	a := asks.Answer{Answers: []asks.QuestionAnswer{{ID: "a", Labels: []string{"Yes"}}}}
	if ok, err := e.h.storeAnswer(s.ask, s.wb, normalizeAnswer(a, asks.Payload{})); err != nil || !ok {
		t.Fatalf("store: %v %v", ok, err)
	}

	got := e.h.askAnswer(context.Background(), e.answerAction(s, yes))

	wantDelivery(t, got, "")
	if n := len(e.port.lines()); n != 0 {
		t.Fatalf("lines delivered = %d, want none", n)
	}
}

// MARK: - Go's answer fixtures

type answerFixture struct {
	Kind      string          `json:"kind"`
	Payload   json.RawMessage `json:"payload"`
	Answer    json.RawMessage `json:"answer"`
	Canonical string          `json:"canonical"`
	Error     string          `json:"error"`
}

func loadFixture(t *testing.T, name string) answerFixture {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "asks", "testdata", "answers", name))
	if err != nil {
		t.Fatal(err)
	}
	var f answerFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestGosValidAnswerFixturesAreStoredAsTheirCanonicalForm(t *testing.T) {
	e := newEnv(t)
	for _, name := range []string{"valid_question.json", "valid_review_changes.json"} {
		f := loadFixture(t, name)
		s := e.seedAsk(f.Kind, string(f.Payload))

		got := e.h.askAnswer(context.Background(), e.answerAction(s, f.Answer))

		wantDelivery(t, got, deliveryNoSession)
		if _, stored := e.stored(s.ask); stored != f.Canonical {
			t.Fatalf("%s: stored\n %s\nwant\n %s", name, stored, f.Canonical)
		}
	}
}

func TestGosInvalidAnswerFixtureIsInvalidAnswerWithGosMessage(t *testing.T) {
	e := newEnv(t)
	f := loadFixture(t, "invalid_review_no_verdict.json")
	s := e.seedAsk(f.Kind, string(f.Payload))

	got := e.h.askAnswer(context.Background(), e.answerAction(s, f.Answer))

	wantOutcome(t, got, wire.StatusFailed, reasonInvalidAnswer)
	if got.Message != f.Error {
		t.Fatalf("message = %q, want %q", got.Message, f.Error)
	}
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatalf("status = %s, want open", st)
	}
}

// MARK: - Deliveries

func TestAStoredAnswerEchoesItsDelivery(t *testing.T) {
	e := newEnv(t)
	// Running → submitted.
	running := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(running.session)
	e.hooksReport(running.session, "waiting")
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(running, yes)), deliverySubmitted)

	// At a permission prompt → held, nothing typed.
	waiting := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(waiting.session)
	e.hooksReport(waiting.session, "approval")
	before := len(e.port.lines())
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(waiting, yes)), deliveryHeld)
	if len(e.port.lines()) != before {
		t.Fatal("a held answer types nothing yet")
	}

	// No running session → no_session (the brief delivers it).
	idle := e.seedAsk(asks.KindQuestion, questions)
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(idle, yes)), deliveryNoSession)
	if st, _ := e.stored(idle.ask); st != "answered" {
		t.Fatalf("status = %s, want answered", st)
	}
}

// An automation run's ask: its answer goes to the run, never to the brief —
// automation, kept for a re-run too; the executor is woken.
func TestAnAutomationAskEchoesAutomation(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	runID := e.automationRun(s.wb, "waiting")
	e.exec(`UPDATE automation_runs SET waiting_reason = 'ask' WHERE id = ?`, runID)
	askID := e.ask(db.OwnerAsk{WorkbenchID: s.wb, Kind: asks.KindQuestion, Payload: questions,
		AutomationRunID: sql.NullInt64{Int64: runID, Valid: true}})
	req := e.request("ask_answer", id(askID), map[string]any{"workbench_id": s.wb, "answer": yes})

	wantDelivery(t, e.h.askAnswer(context.Background(), req), deliveryAutomation)
	if st, _ := e.stored(askID); st != "answered" {
		t.Fatalf("status = %s", st)
	}
	wantDelivery(t, e.h.askAnswer(context.Background(), req), deliveryAutomation)
	if e.woken != 1 {
		t.Fatalf("woken = %d, want 1", e.woken)
	}
	if n := len(e.port.lines()); n != 0 {
		t.Fatalf("lines = %d, want none", n)
	}
}

// Every host outcome maps to its echo (testEveryOutcomeMapsToItsEcho).
func TestEveryOutcomeMapsToItsEcho(t *testing.T) {
	for host, want := range map[string]string{
		DeliverSubmitted: deliverySubmitted, DeliverTyped: deliveryTyped,
		DeliverHeld: deliveryHeld, DeliverNoSession: deliveryNoSession,
	} {
		e := newEnv(t)
		s := e.seedAsk(asks.KindQuestion, questions)
		e.port.start(s.session)
		e.port.result = DeliverResult{Outcome: host, Reason: "prompt_has_text"}
		wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), want)
	}
}

// PROJ-12 (controller ruling, Swift parity): an answer line is one line with
// the submitSettle pause and no kept line breaks or format characters, sent
// without HoldIfPromptText — over the owner's draft the host pastes it and
// leaves it typed, and the echo says typed.
func TestAnAnswerLineIsTypedBesideTheOwnersDraft(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverTyped}
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryTyped)
	lines := e.port.lines()
	if len(lines) != 1 {
		t.Fatalf("lines = %d", len(lines))
	}
	l := lines[0]
	want := asks.DeliveryLine(s.ask, asks.KindQuestion, asks.Answer{})
	if l.HoldIfPromptText || l.KeepLineBreaks || l.KeepFormat || l.Settle != submitSettle || l.Run != 1 || l.Text != want {
		t.Fatalf("request = %+v", l)
	}
}

// The re-check after the pause vouches for a Return only with this run's
// hooks and no permission prompt.
func TestTheRecheckVouchesOnlyForThisRunsHooks(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.h.askAnswer(context.Background(), e.answerAction(s, yes))
	if c := e.port.checks[0]; !c.Fresh || c.CanSubmit || c.AnswersDialog {
		t.Fatalf("no hook state this run: check = %+v", c)
	}

	s2 := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s2.session)
	e.hooksReport(s2.session, "waiting")
	e.h.askAnswer(context.Background(), e.answerAction(s2, yes))
	if c := e.port.checks[1]; !c.Fresh || !c.CanSubmit || c.AnswersDialog {
		t.Fatalf("hooks report: check = %+v", c)
	}

	s3 := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s3.session)
	e.hooksReport(s3.session, "waiting")
	e.port.onDeliver = func(DeliverRequest) { e.hooksReport(s3.session, "approval") }
	e.h.askAnswer(context.Background(), e.answerAction(s3, yes))
	if c := e.port.checks[2]; !c.Fresh || c.CanSubmit || !c.AnswersDialog {
		t.Fatalf("a prompt during the pause: check = %+v", c)
	}
}

// A held answer goes on the next read of the session states once the
// permission prompt is gone, and never into a later launch.
func TestAHeldAnswerGoesOnTheNextStateRead(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryHeld)

	e.h.DeliverHeld(context.Background())
	if len(e.port.lines()) != 0 || len(e.h.held) != 1 {
		t.Fatal("still at the prompt: still held, nothing typed")
	}
	e.hooksReport(s.session, "waiting")
	e.h.DeliverHeld(context.Background())
	if len(e.port.lines()) != 1 || len(e.h.held) != 0 {
		t.Fatalf("lines = %d held = %d, want the line typed once", len(e.port.lines()), len(e.h.held))
	}

	// A relaunch: the held line is meant for the run before; its brief has it.
	s2 := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s2.session)
	e.hooksReport(s2.session, "approval")
	e.h.askAnswer(context.Background(), e.answerAction(s2, yes))
	e.port.live[s2.session] = LiveRun{SessionID: s2.session, Run: 2, StartedAt: time.Now()}
	e.hooksReport(s2.session, "waiting")
	e.h.DeliverHeld(context.Background())
	if len(e.port.lines()) != 1 || len(e.h.held) != 0 {
		t.Fatal("a relaunched session never gets the held line")
	}
}

// A held answer survives a hub restart (session-host keeps the session):
// hub_meta keeps only its ids, the line comes back from owner_asks.
func TestAHeldAnswerSurvivesAHubRestart(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryHeld)
	if raw, _, _ := e.store.Meta(heldMetaKey); strings.Contains(raw, "answered") || !strings.Contains(raw, `"ask":`) {
		t.Fatalf("hub_meta = %q, want ids only", raw)
	}

	restarted := Register(actions.NewDispatcher(), e.h.d)
	e.hooksReport(s.session, "waiting")
	restarted.DeliverHeld(context.Background())

	lines := e.port.lines()
	if len(lines) != 1 || lines[0].Text != asks.DeliveryLine(s.ask, asks.KindQuestion, asks.Answer{}) {
		t.Fatalf("lines = %+v", lines)
	}
	if again := Register(actions.NewDispatcher(), e.h.d); len(again.held) != 0 {
		t.Fatal("a delivered answer is not held again after the next restart")
	}
}

// An answer the brief delivered meanwhile is not rebuilt at start.
func TestAHeldAnswerTheBriefDeliveredIsDropped(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.hooksReport(s.session, "approval")
	e.h.askAnswer(context.Background(), e.answerAction(s, yes))
	e.exec(`UPDATE owner_asks SET status = 'delivered' WHERE id = ?`, s.ask)

	if restarted := Register(actions.NewDispatcher(), e.h.d); len(restarted.held) != 0 {
		t.Fatal("a delivered answer is not held")
	}
}

// A failed read of the host holds the answer, as a failed state read does.
func TestALiveErrorHoldsTheAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.liveErr = errors.New("host busy")
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryHeld)
	e.h.DeliverHeld(context.Background())
	if len(e.h.held) != 1 || len(e.port.lines()) != 0 {
		t.Fatal("still held while the host cannot be read")
	}
	e.port.liveErr = nil
	e.h.DeliverHeld(context.Background())
	if len(e.h.held) != 0 || len(e.port.lines()) != 1 {
		t.Fatal("goes once the host answers")
	}
}

// N1 (PROJ-12): a line held before its launch was known (the host could not
// be read) never goes into a launch started after the answer was stored —
// that launch's brief already lists it — before or after a hub restart.
func TestAnUnpinnedHeldLineNeverGoesIntoALaterLaunch(t *testing.T) {
	for _, restart := range []bool{false, true} {
		e := newEnv(t)
		s := e.seedAsk(asks.KindQuestion, questions)
		e.port.start(s.session)
		e.port.liveErr = errors.New("host busy")
		wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryHeld)
		e.port.liveErr = nil
		e.port.live[s.session] = LiveRun{SessionID: s.session, Run: 2, StartedAt: time.Now().Add(2 * time.Second)}
		h := e.h
		if restart {
			h = Register(actions.NewDispatcher(), e.h.d)
		}

		h.DeliverHeld(context.Background())

		if len(e.port.lines()) != 0 || len(h.held) != 0 {
			t.Fatalf("restart=%v: lines = %d held = %d, want the line dropped", restart, len(e.port.lines()), len(h.held))
		}
	}
}

// N2: each held line leaves hub_meta just before its own delivery, so a
// crash mid-loop loses at most the line in flight.
func TestEachHeldLineLeavesTheStoreJustBeforeItsDelivery(t *testing.T) {
	e := newEnv(t)
	first := e.seedAsk(asks.KindQuestion, questions)
	second := e.seedAsk(asks.KindQuestion, questions)
	for _, s := range []seeded{first, second} {
		e.port.start(s.session)
		e.hooksReport(s.session, "approval")
		wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryHeld)
		e.hooksReport(s.session, "waiting")
	}
	var stored []string
	e.port.onDeliver = func(DeliverRequest) {
		raw, _, _ := e.store.Meta(heldMetaKey)
		stored = append(stored, raw)
	}

	e.h.DeliverHeld(context.Background())

	if len(stored) != 2 {
		t.Fatalf("deliveries = %d", len(stored))
	}
	ask := func(id int64) string { return `"ask":` + strconv.FormatInt(id, 10) + "," }
	if strings.Contains(stored[0], ask(first.ask)) || !strings.Contains(stored[0], ask(second.ask)) {
		t.Fatalf("during the first delivery hub_meta = %s, want only the second ask", stored[0])
	}
	if strings.Contains(stored[1], ask(second.ask)) {
		t.Fatalf("during the second delivery hub_meta = %s", stored[1])
	}
}

// N3: a held line goes only while its ask is still answered — not once the
// agent read it (delivered) or it was withdrawn.
func TestAHeldLineOfAnAskNoLongerAnsweredIsSkipped(t *testing.T) {
	for _, status := range []string{"delivered", "withdrawn"} {
		e := newEnv(t)
		s := e.seedAsk(asks.KindQuestion, questions)
		e.port.start(s.session)
		e.hooksReport(s.session, "approval")
		e.h.askAnswer(context.Background(), e.answerAction(s, yes))
		e.hooksReport(s.session, "waiting")
		if status == "withdrawn" {
			e.exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent', answer = '' WHERE id = ?`, s.ask)
		} else {
			e.exec(`UPDATE owner_asks SET status = ? WHERE id = ?`, status, s.ask)
		}

		e.h.DeliverHeld(context.Background())

		if len(e.port.lines()) != 0 || len(e.h.held) != 0 {
			t.Fatalf("%s: lines = %d held = %d", status, len(e.port.lines()), len(e.h.held))
		}
	}
}

func TestNoPasteModeIsCopiedOnADesktopHost(t *testing.T) {
	e := newEnv(t)
	e.desktop = true
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverNoPasteMode}

	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryCopied)
	if len(e.clip) != 1 || e.clip[0] != asks.DeliveryLine(s.ask, asks.KindQuestion, asks.Answer{}) {
		t.Fatalf("clipboard = %q", e.clip)
	}
}

func TestNoPasteModeIsCannotTypeOnACLIOnlyMac(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverNoPasteMode}

	req := e.answerAction(s, yes)

	got := e.h.askAnswer(context.Background(), req)

	wantOutcome(t, got, wire.StatusFailed, reasonCannotType)
	if got.Message != "Your answer was saved. This session can't take typed text right now" {
		t.Fatalf("message = %q", got.Message)
	}
	if len(e.clip) != 0 {
		t.Fatal("the clipboard is never used without a Desktop heartbeat")
	}
	if st, _ := e.stored(s.ask); st != "answered" {
		t.Fatal("the answer itself is stored")
	}
	// A re-run of the action says the same, never applied.
	wantOutcome(t, e.h.askAnswer(context.Background(), req), wire.StatusFailed, reasonCannotType)
}

// The guarded UPDATE … WHERE status='open' commits before Deliver is called;
// zero rows → ask_not_open and nothing delivered.
func TestAskAnswerIsStoredBeforeAnythingIsDelivered(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	var statusAtDeliver string
	e.port.onDeliver = func(DeliverRequest) {
		statusAtDeliver = e.scalar(`SELECT status FROM owner_asks WHERE id = ?`, s.ask)
	}
	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliverySubmitted)
	if statusAtDeliver != "answered" {
		t.Fatalf("status at Deliver = %q, want answered", statusAtDeliver)
	}

	// Open, but hidden in the spec review's author loop: the guarded write
	// changes nothing.
	hidden := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(hidden.session)
	e.exec(`INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES (?, 'running', '2026-10-25T10:00:00Z', 'author')`, hidden.ask)
	before := len(e.port.lines())
	got := e.h.askAnswer(context.Background(), e.answerAction(hidden, yes))
	wantOutcome(t, got, wire.StatusFailed, reasonAskNotOpen)
	if len(e.port.lines()) != before {
		t.Fatal("nothing is delivered for an answer not stored")
	}
}

// MARK: - Not open

// The agent superseded the ask while the owner drafted on the phone.
func TestASupersededAskIsNotOpen(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.ask(db.OwnerAsk{WorkbenchID: s.wb, SessionID: sql.NullInt64{Int64: s.session, Valid: true}, Kind: asks.KindQuestion,
		Payload: questions, PreviousAskID: sql.NullInt64{Int64: s.ask, Valid: true}})

	got := e.h.askAnswer(context.Background(), e.answerAction(s, yes))

	wantOutcome(t, got, wire.StatusFailed, reasonAskNotOpen)
	if _, a := e.stored(s.ask); a != "" {
		t.Fatalf("answer = %q", a)
	}
	if len(e.port.lines()) != 0 {
		t.Fatal("nothing typed")
	}
}

func TestAnAskAnsweredOnTheMacIsNotOpen(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	mac := `{"answers":[{"id":"a","labels":["No"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
	e.exec(`UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?`, mac, s.ask)

	got := e.h.askAnswer(context.Background(), e.answerAction(s, yes))

	wantOutcome(t, got, wire.StatusFailed, reasonAskNotOpen)
	if _, a := e.stored(s.ask); a != mac {
		t.Fatal("the Mac's answer stays")
	}
	if len(e.port.lines()) != 0 {
		t.Fatal("nothing typed")
	}
}

// MARK: - Invalid

func TestAnUnknownLabelIsInvalidAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	maybe := map[string]any{"answers": []any{map[string]any{"id": "a", "labels": []string{"Maybe"}}}}

	got := e.h.askAnswer(context.Background(), e.answerAction(s, maybe))

	wantOutcome(t, got, wire.StatusFailed, reasonInvalidAnswer)
	if got.Message != `answers[0].labels: question "a" has no option "Maybe"` {
		t.Fatalf("message = %q", got.Message)
	}
	if st, _ := e.stored(s.ask); st != "open" || len(e.port.lines()) != 0 {
		t.Fatal("nothing written or typed")
	}
}

func TestAReviewWithoutAVerdictIsInvalidAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("")))

	wantOutcome(t, got, wire.StatusFailed, reasonInvalidAnswer)
	if got.Message != "verdict: required for a review" {
		t.Fatalf("message = %q", got.Message)
	}
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatal("still open")
	}
}

// F5: the phone's answer to a review ask carries the spec review's comment
// marks, read from the database at answer time.
func TestAReviewAnswerFromThePhoneCarriesTheSpecReviewMarks(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")
	e.exec(`UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?`, "# Spec\nThe plan text\n", s.ask)
	e.exec(`INSERT INTO spec_reviews (ask_id, status, queued_at) VALUES (?, 'running', '2026-10-25T10:00:00Z')`, s.ask)
	e.exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at)
		VALUES (?, 'ag:1', 'comment', 'say when', 'Mute lasts a day', '2026-10-25T10:00:00Z')`, s.ask)

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("changes")))

	st, raw := e.stored(s.ask)
	if st == "open" {
		t.Fatalf("not stored: %+v", got)
	}
	a, err := asks.ParseAnswer([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Comments) != 1 || a.Comments[0].Body != "From the previous run: Mute lasts a day — say when" {
		t.Fatalf("comments = %+v", a.Comments)
	}
	if a.Comments[0].Heading != "Spec" || a.Comments[0].Quote != "The plan text" {
		t.Fatalf("anchor = %+v", a.Comments[0])
	}
}

func TestAWhitespaceOnlyCommentIsInvalidAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")
	blank := map[string]any{"quote": "migrate every row", "prefix": "Step 2: ", "suffix": ".", "heading": "Rollout", "body": "  \n\t "}

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("changes", blank)))

	wantOutcome(t, got, wire.StatusFailed, reasonInvalidAnswer)
	if got.Message != "comments[0].body: required" {
		t.Fatalf("message = %q", got.Message)
	}
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatal("still open")
	}
}

// A finished author loop whose ledger cannot be read is an error, never sent
// as plain review comments.
func TestAnUnreadableLoopLedgerIsWriteFailed(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")
	e.exec(`INSERT INTO spec_reviews (ask_id, status, queued_at, loop, ledger) VALUES (?, 'done', '2026-10-25T10:00:00Z', 'owner', '{not json')`, s.ask)
	e.exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at)
		VALUES (?, 'ag:1', 'comment', 'say when', 'Mute lasts a day', '2026-10-25T10:00:00Z')`, s.ask)

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("changes")))

	wantOutcome(t, got, wire.StatusFailed, reasonWriteFailed)
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatal("nothing stored")
	}
}

func TestAnUnreadableAnswerIsInvalidAnswer(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("maybe")))

	wantOutcome(t, got, wire.StatusFailed, reasonInvalidAnswer)
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatal("still open")
	}
}

// MARK: - Scope and params

func TestAnAskOfAnotherWorkbenchIsNotFound(t *testing.T) {
	e := newEnv(t)
	mine := e.seedAsk(asks.KindQuestion, questions)
	other := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(other.session)

	crossed := e.h.askAnswer(context.Background(), e.answerAction(seeded{wb: mine.wb, ask: other.ask}, yes))
	missing := e.h.askAnswer(context.Background(), e.answerAction(seeded{wb: other.wb, ask: other.ask + 1000}, yes))

	wantOutcome(t, crossed, wire.StatusFailed, reasonNotFound)
	wantOutcome(t, missing, wire.StatusFailed, reasonNotFound)
	if st, _ := e.stored(other.ask); st != "open" || len(e.port.lines()) != 0 {
		t.Fatal("nothing written or typed")
	}
}

func TestMissingParamsAreInvalidParams(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	for _, req := range []actions.Request{
		e.request("ask_answer", id(s.ask), map[string]any{"answer": yes}),
		e.request("ask_answer", id(s.ask), map[string]any{"workbench_id": s.wb}),
		e.request("ask_answer", nil, map[string]any{"workbench_id": s.wb, "answer": yes}),
	} {
		wantOutcome(t, e.h.askAnswer(context.Background(), req), wire.StatusFailed, reasonInvalidParams)
	}
	if st, _ := e.stored(s.ask); st != "open" {
		t.Fatal("still open")
	}
}

func TestAFailedWriteIsWriteFailed(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.exec(`CREATE TRIGGER fail_ask_answer BEFORE UPDATE ON owner_asks BEGIN SELECT RAISE(ABORT, 'disk full'); END`)

	got := e.h.askAnswer(context.Background(), e.answerAction(s, yes))

	wantOutcome(t, got, wire.StatusFailed, reasonWriteFailed)
	if !strings.Contains(got.Message, "disk full") {
		t.Fatalf("message = %q", got.Message)
	}
	if len(e.port.lines()) != 0 {
		t.Fatal("nothing typed")
	}
}

// MARK: - Timeout

func TestAHungAnswerIsCutByTheHandlersTimeout(t *testing.T) {
	e := newEnv(t)
	e.h.d.Timeout = 50 * time.Millisecond
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	release := make(chan struct{})
	entered := make(chan struct{})
	e.port.onDeliver = func(DeliverRequest) {
		close(entered)
		<-release
	}

	got := e.h.askAnswer(context.Background(), e.answerAction(s, yes))

	if got.Status != wire.StatusFailed || got.Reason != reasonOutcomeUnknown || got.Message != askTimeoutMessage {
		t.Fatalf("outcome = %+v", got)
	}
	select {
	case <-entered:
	default:
		t.Fatal("the answer was not running when the timeout fired")
	}
	close(release)
}

func TestAnAnswerFasterThanTheTimeoutIsItsOwnOutcome(t *testing.T) {
	e := newEnv(t)
	s := e.seedAsk(asks.KindQuestion, questions)
	e.port.start(s.session)
	e.port.result = DeliverResult{Outcome: DeliverTyped}

	wantDelivery(t, e.h.askAnswer(context.Background(), e.answerAction(s, yes)), deliveryTyped)
}
