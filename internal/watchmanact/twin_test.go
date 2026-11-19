package watchmanact

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/providers"
	"watchtower/internal/watchman"
)

// twinSessions is a session-host with one scripted answer: live sessions
// take every line (submitted); any other session is gone.
type twinSessions struct {
	mu    sync.Mutex
	live  map[int64]bool
	lines []askanswer.DeliverRequest
	// onDeliver runs inside Deliver, after the answer's commit.
	onDeliver func()
}

func (s *twinSessions) Live(_ context.Context, id int64) (askanswer.LiveRun, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.live[id] {
		return askanswer.LiveRun{}, false, nil
	}
	return askanswer.LiveRun{SessionID: id, Run: 1, Agent: "claude", StartedAt: time.Now().Add(-time.Minute)}, true, nil
}

func (s *twinSessions) Deliver(_ context.Context, r askanswer.DeliverRequest) (askanswer.DeliverResult, error) {
	s.mu.Lock()
	s.lines = append(s.lines, r)
	hook := s.onDeliver
	s.mu.Unlock()
	if hook != nil {
		hook()
	}
	return askanswer.DeliverResult{Outcome: askanswer.DeliverSubmitted}, nil
}

func (s *twinSessions) delivered() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.lines)
}

type startCall struct {
	workbench, target int64
	brief             string
}

// twinEnv is a learned workbench with one armed, live session on a target,
// the twin over fakes for the model, the label check and session starts.
type twinEnv struct {
	t                   *testing.T
	db                  *db.DB
	port                *twinSessions
	wb, session, target int64
	mu                  sync.Mutex
	decideFn            func(ctx context.Context, it watchman.Item) (watchman.Decision, error)
	parkedFn            func(ctx context.Context, text string) (bool, string, error)
	decided             []watchman.Item
	labelled            []string
	started             []startCall
	twin                *Twin
}

func newTwinEnv(t *testing.T) *twinEnv {
	t.Helper()
	e := &twinEnv{t: t, db: db.OpenTestDB(t), port: &twinSessions{live: map[int64]bool{}}}
	wb, err := e.db.CreateWorkbench("acme", t.TempDir())
	e.must(err)
	e.wb = wb
	e.must(e.db.EnableWatchmanWorkbench(wb, time.Now().Add(-48*time.Hour), 10))
	e.must(e.db.MarkWatchmanLearned(wb, time.Now().Add(-time.Hour)))
	res, err := e.db.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES ('Ship the export', 'custom', 'project', '2026-11-18', '2026-11-18', 'chat', ?)`, wb)
	e.must(err)
	e.target, _ = res.LastInsertId()
	res, err = e.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, target_id, agent_state, agent_state_at)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid', ?, 'waiting', ?)`, wb, e.target, db.AgentStateStamp(time.Now()))
	e.must(err)
	e.session, _ = res.LastInsertId()
	e.port.live[e.session] = true
	e.arm()
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) { return decision("SQLite"), nil }
	e.parkedFn = func(context.Context, string) (bool, string, error) { return false, "", nil }
	e.twin = NewTwin(TwinDeps{
		DB:       e.db,
		Answerer: askanswer.New(askanswer.Deps{DB: e.db, Sessions: e.port}),
		Decide: func(ctx context.Context, it watchman.Item) (watchman.Decision, error) {
			e.mu.Lock()
			e.decided = append(e.decided, it)
			fn := e.decideFn
			e.mu.Unlock()
			return fn(ctx, it)
		},
		Parked: func(ctx context.Context, text string) (bool, string, error) {
			e.mu.Lock()
			e.labelled = append(e.labelled, text)
			fn := e.parkedFn
			e.mu.Unlock()
			return fn(ctx, text)
		},
		StartSession: func(_ context.Context, wb, target int64, brief string) error {
			e.mu.Lock()
			defer e.mu.Unlock()
			e.started = append(e.started, startCall{wb, target, brief})
			return nil
		},
	})
	return e
}

func (e *twinEnv) must(err error) {
	e.t.Helper()
	if err != nil {
		e.t.Fatal(err)
	}
}

func (e *twinEnv) arm() {
	e.must(e.db.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: e.session, ArmedAt: time.Now(), ArmedBy: "cli"}))
}

func (e *twinEnv) disarm() {
	_, err := e.db.DeleteWatchmanArming("session", e.session)
	e.must(err)
}

func (e *twinEnv) decideCalls() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.decided)
}

func decision(choice string) watchman.Decision {
	return watchman.Decision{Choice: choice, Rationale: "the owner keeps data local", Category: "design",
		Confidence: "high", Importance: "low", Handoff: watchman.HandoffNone, PrecedentIDs: []int64{7}}
}

const oneQuestion = `{"questions":[{"id":"a","question":"Which store?","options":[{"label":"SQLite"},{"label":"Files"}]}]}`

// fileAsk files an open ask of kind with payload from the armed session and
// queues its item of itemKind.
func (e *twinEnv) fileAsk(kind, title, payload, itemKind string) (askID, itemID int64) {
	e.t.Helper()
	e.must(e.db.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = e.db.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: e.wb, SessionID: sql.NullInt64{Int64: e.session, Valid: true},
			TargetID: sql.NullInt64{Int64: e.target, Valid: true}, Kind: kind, Title: title, Payload: payload,
		})
		return err
	}))
	itemID, inserted, err := e.db.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session, TargetID: e.target,
		Kind: itemKind, RefKind: "ask", RefID: askID, Question: title})
	e.must(err)
	if !inserted {
		e.t.Fatal("item not queued")
	}
	return askID, itemID
}

func (e *twinEnv) question(title string) (askID, itemID int64) {
	return e.fileAsk(asks.KindQuestion, title, oneQuestion, "ask")
}

// run is one RunOnce and the wait for what it started.
func (e *twinEnv) run() int {
	n := e.twin.RunOnce(context.Background())
	e.twin.Wait()
	return n
}

func (e *twinEnv) item(id int64) db.WatchmanItem {
	e.t.Helper()
	var it db.WatchmanItem
	var prec string
	var unsure int
	e.must(e.db.QueryRow(`SELECT state, outcome, attempts, choice, rationale, precedent_ids, unsure, park_reason, delivery, error, category, confidence
		FROM watchman_items WHERE id = ?`, id).Scan(&it.State, &it.Outcome, &it.Attempts, &it.Choice, &it.Rationale, &prec, &unsure,
		&it.ParkReason, &it.Delivery, &it.Error, &it.Category, &it.Confidence))
	it.Unsure = unsure == 1
	e.must(json.Unmarshal([]byte(prec), &it.PrecedentIDs))
	return it
}

func (e *twinEnv) askAnswer(id int64) (string, asks.Answer) {
	e.t.Helper()
	a, err := e.db.GetOwnerAskByID(id)
	e.must(err)
	if a.Answer == "" {
		return a.Status, asks.Answer{}
	}
	ans, err := asks.ParseAnswer([]byte(a.Answer))
	e.must(err)
	return a.Status, ans
}

func wantOutcome(t *testing.T, it db.WatchmanItem, outcome string) {
	t.Helper()
	if it.State != "done" || it.Outcome != outcome {
		t.Fatalf("item = %s/%q, want done/%q (park reason %q, error %q)", it.State, it.Outcome, outcome, it.ParkReason, it.Error)
	}
}

// wantParked checks the item parked for reason and the ask answered
// "Parked for the owner: <reason>".
func (e *twinEnv) wantParked(askID, itemID int64, reason string) {
	e.t.Helper()
	it := e.item(itemID)
	wantOutcome(e.t, it, OutcomeParked)
	if !strings.Contains(it.ParkReason, reason) {
		e.t.Fatalf("park reason = %q, want it to contain %q", it.ParkReason, reason)
	}
	status, ans := e.askAnswer(askID)
	if status != "answered" || len(ans.Answers) != 1 || ans.Answers[0].Other != ParkedPrefix+it.ParkReason {
		e.t.Fatalf("ask = %s %+v, want answered %q", status, ans, ParkedPrefix+it.ParkReason)
	}
}

func TestTwin_AnswersAskUnsure(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want 1", n)
	}
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if !it.Unsure || it.Choice != "SQLite" || it.Rationale != "the owner keeps data local" || len(it.PrecedentIDs) != 1 || it.PrecedentIDs[0] != 7 {
		t.Fatalf("item = %+v, want unsure with the choice, rationale and precedents", it)
	}
	if it.Delivery != askanswer.DeliverySubmitted {
		t.Fatalf("delivery = %q, want submitted", it.Delivery)
	}
	status, ans := e.askAnswer(askID)
	if status != "answered" || len(ans.Answers) != 1 || len(ans.Answers[0].Labels) != 1 || ans.Answers[0].Labels[0] != "SQLite" {
		t.Fatalf("ask = %s %+v, want the option SQLite", status, ans)
	}
	if got := e.decided[0]; got.Category != "" || len(got.Options) != 2 || got.WorkbenchID != e.wb || !strings.Contains(got.Situation, "Which store?") {
		t.Fatalf("Decide item = %+v", got)
	}
}

func TestTwin_OwnerFirstJournalledNothingDelivered(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	owner := `{"answers":[{"id":"a","labels":["Files"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		// The owner answers at the Mac while the twin's model call runs.
		_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = '2026-11-18T08:00:00Z' WHERE id = ?`, owner, askID)
		e.must(err)
		return decision("SQLite"), nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	if n := e.port.delivered(); n != 0 {
		t.Fatalf("%d lines delivered, want none", n)
	}
	if _, ans := e.askAnswer(askID); ans.Answers[0].Labels[0] != "Files" {
		t.Fatalf("the owner's answer was overwritten: %+v", ans)
	}
}

func TestTwin_OwnerAnsweredBeforeLeaseIsOwnerFirst(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"answers":[{"id":"a","labels":["Files"],"other":""}]}', answered_at = '2026-11-18T08:00:00Z' WHERE id = ?`, askID)
	e.must(err)
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran on an ask the owner had answered")
	}
}

func TestTwin_WithdrawnAskDropsItem(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	_, err := e.db.Exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'superseded' WHERE id = ?`, askID)
	e.must(err)
	e.run()
	var n int
	e.must(e.db.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE id = ?`, itemID).Scan(&n))
	if n != 0 || e.decideCalls() != 0 {
		t.Fatalf("a superseded ask's item stayed (%d) or was decided (%d)", n, e.decideCalls())
	}
}

func TestWATCHMAN04_NothingActsOnUnarmedSession(t *testing.T) {
	for _, c := range []struct {
		name  string
		unarm func(e *twinEnv)
	}{
		{"never armed", func(e *twinEnv) { e.disarm() }},
		{"disarmed", func(e *twinEnv) { e.disarm(); e.arm(); e.disarm() }},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTwinEnv(t)
			_, itemID := e.question("Which store?")
			c.unarm(e)
			if n := e.run(); n != 0 {
				t.Fatalf("RunOnce = %d, want 0", n)
			}
			if it := e.item(itemID); it.State != "queued" || it.Attempts != 0 {
				t.Fatalf("item = %+v, want queued untouched", it)
			}
			if e.decideCalls() != 0 {
				t.Fatal("Decide ran for an unarmed session")
			}
		})
	}
}

func TestTwin_ActsWhileOwnerPresent(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.question("Which store?")
	// D47: the owner looking at the armed session does not stop the twin.
	_, err := e.db.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, ?, ?)`, e.session, db.AgentStateStamp(time.Now()))
	e.must(err)
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want 1", n)
	}
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
}

func TestTwin_ArmingReadErrorLeavesQueued(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.question("Which store?")
	_, err := e.db.Exec(`DROP TABLE watchman_arming`)
	e.must(err)
	if n := e.run(); n != 0 {
		t.Fatalf("RunOnce = %d, want 0 (fail closed)", n)
	}
	if it := e.item(itemID); it.State != "queued" || e.decideCalls() != 0 {
		t.Fatalf("item = %s, %d decisions; want queued, none", it.State, e.decideCalls())
	}
}

func TestTwin_DisarmLeavesQueued(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.question("Which store?")
	e.disarm()
	if n := e.run(); n != 0 || e.item(itemID).State != "queued" {
		t.Fatalf("RunOnce = %d, state %s; want 0, queued", n, e.item(itemID).State)
	}
}

func TestTwin_DecidingItemFinishesAfterDisarm(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.question("Which store?")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		e.disarm() // Take back while the model call runs
		return decision("SQLite"), nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
}

func TestTwin_LeaseExpiryRetakenThenParked(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		e := newTwinEnv(t)
		askID, itemID := e.question("Which store?")
		release := make(chan struct{})
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			<-release // the Mac slept: the call never returns within its lease
			return decision("SQLite"), nil
		}
		ctx := context.Background()
		for attempt := 1; attempt <= MaxAttempts; attempt++ {
			if n := e.twin.RunOnce(ctx); n != 1 {
				t.Fatalf("attempt %d: RunOnce = %d, want 1", attempt, n)
			}
			synctest.Wait()
			if it := e.item(itemID); it.State != "deciding" || it.Attempts != attempt {
				t.Fatalf("attempt %d: item %s/%d", attempt, it.State, it.Attempts)
			}
			if n := e.twin.RunOnce(ctx); n != 0 {
				t.Fatalf("attempt %d: a live lease was retaken", attempt)
			}
			time.Sleep(LeaseFor + time.Second)
		}
		if n := e.twin.RunOnce(ctx); n != 1 {
			t.Fatalf("final RunOnce = %d, want 1", n)
		}
		synctest.Wait()
		close(release) // the stale attempts return: their writes are refused
		e.twin.Wait()
		e.wantParked(askID, itemID, "could not decide this in 3 attempts")
		if e.decideCalls() != MaxAttempts {
			t.Fatalf("Decide ran %d times, want %d", e.decideCalls(), MaxAttempts)
		}
	})
}

func TestTwin_ProviderRefusalRetriesOnceThenParks(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		e := newTwinEnv(t)
		askID, itemID := e.question("Which store?")
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return watchman.Decision{}, providers.WithFailure("claude", providers.Quota, errors.New("plan limit reached"))
		}
		start := time.Now()
		e.run()
		it := e.item(itemID)
		if it.State != "queued" || !strings.Contains(it.Error, "plan limit reached") {
			t.Fatalf("after the first refusal: %+v", it)
		}
		var notBefore string
		e.must(e.db.QueryRow(`SELECT not_before FROM watchman_items WHERE id = ?`, itemID).Scan(&notBefore))
		if want := start.Add(ProviderRetry).UTC().Format(time.RFC3339); notBefore != want {
			t.Fatalf("not_before = %s, want %s", notBefore, want)
		}
		time.Sleep(ProviderRetry - time.Minute)
		if n := e.run(); n != 0 {
			t.Fatalf("leased %d before the retry time", n)
		}
		time.Sleep(time.Minute)
		if n := e.run(); n != 1 {
			t.Fatalf("retry RunOnce = %d, want 1", n)
		}
		e.wantParked(askID, itemID, "plan limit reached")
		if e.decideCalls() != 2 {
			t.Fatalf("Decide ran %d times, want 2", e.decideCalls())
		}
	})
}

func TestTwin_HardLimitParksBeforeModel(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Merge feature/x into main now?")
	e.run()
	e.wantParked(askID, itemID, "a merge, push or rebase onto main")
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran on a hard limit")
	}
}

func TestTwin_LabelOnlyAddsPark(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	e.parkedFn = func(context.Context, string) (bool, string, error) {
		return true, "the label says the owner decides", nil
	}
	e.run()
	e.wantParked(askID, itemID, "the label says the owner decides")
	if e.decideCalls() != 0 {
		t.Fatal("Decide ran after the label parked")
	}
}

func TestTwin_LabelErrorParks(t *testing.T) {
	cases := []struct {
		name   string
		parked func(ctx context.Context, text string) (bool, string, error)
	}{
		{"error", func(context.Context, string) (bool, string, error) { return false, "", errors.New("provider down") }},
		{"timeout", func(ctx context.Context, _ string) (bool, string, error) { <-ctx.Done(); return false, "", ctx.Err() }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				e := newTwinEnv(t)
				askID, itemID := e.question("Which store?")
				e.parkedFn = c.parked
				e.run()
				e.wantParked(askID, itemID, reasonLabelFailed)
				if e.decideCalls() != 0 {
					t.Fatal("Decide ran after the label check failed")
				}
			})
		})
	}
}

func TestTwin_ChoiceParkedAfterModel(t *testing.T) {
	e := newTwinEnv(t)
	// An option naming main is not a decision: the twin may choose it or not.
	payload := `{"questions":[{"id":"a","question":"What next?","options":[{"label":"Merge into main"},{"label":"Wait"}]}]}`
	askID, itemID := e.fileAsk(asks.KindQuestion, "What next?", payload, "ask")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return decision("Merge into main"), nil
	}
	e.run()
	e.wantParked(askID, itemID, "a merge, push or rebase onto main")
	if e.decideCalls() != 1 {
		t.Fatalf("Decide ran %d times, want 1 (the option did not park before the model)", e.decideCalls())
	}
	if strings.Contains(e.labelled[0], "Merge into main") {
		t.Fatalf("the before-check read the options: %q", e.labelled[0])
	}

	// Choosing the other option is answered.
	e3 := newTwinEnv(t)
	_, itemID = e3.fileAsk(asks.KindQuestion, "What next?", payload, "ask")
	e3.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) { return decision("Wait"), nil }
	e3.run()
	wantOutcome(t, e3.item(itemID), OutcomeAnswered)

	// The label call on question + choice parks too (the Go table is clean).
	e2 := newTwinEnv(t)
	askID, itemID = e2.question("Which store?")
	e2.parkedFn = func(_ context.Context, text string) (bool, string, error) {
		return strings.Contains(text, "SQLite\n") || strings.HasSuffix(text, "SQLite"), "the choice needs the owner", nil
	}
	e2.run()
	e2.wantParked(askID, itemID, "the choice needs the owner")
}

func TestTwin_UnlearnedWorkbenchParks(t *testing.T) {
	cases := []struct {
		name  string
		setup func(e *twinEnv)
	}{
		{"not learned", func(e *twinEnv) {
			_, err := e.db.Exec(`UPDATE watchman_workbenches SET learned_through = NULL WHERE workbench_id = ?`, e.wb)
			e.must(err)
		}},
		{"relabel pending", func(e *twinEnv) {
			_, err := e.db.Exec(`INSERT INTO watchman_precedents (workbench_id, source, source_key, category, situation, decided_at)
				VALUES (?, 'ask', '1', 'design', 'Which store?', '2026-11-01T00:00:00Z')`, e.wb)
			e.must(err)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newTwinEnv(t)
			askID, itemID := e.question("Which store?")
			c.setup(e)
			e.run()
			e.wantParked(askID, itemID, LearningReason)
			if e.decideCalls() != 0 {
				t.Fatal("Decide ran while learning")
			}
		})
	}
}

func TestTwin_HandoffAnswersHanded(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		d := decision("SQLite")
		d.Handoff, d.Rationale = watchman.HandoffOwnerOnly, "Sign in to the store's console"
		return d, nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeHanded)
	_, ans := e.askAnswer(askID)
	if ans.Answers[0].Other != HandedPrefix+"Sign in to the store's console" || len(ans.Answers[0].Labels) != 0 {
		t.Fatalf("answer = %+v, want the hand-back line, no option", ans)
	}
}

func TestTwin_CheckAnswersFixedText(t *testing.T) {
	e := newTwinEnv(t)
	payload := `{"checklist":[{"id":"c1","text":"The export opens"},{"id":"c2","text":"No crash"}]}`
	askID, itemID := e.fileAsk(asks.KindCheck, "Check the export", payload, "check")
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	_, ans := e.askAnswer(askID)
	if ans.Note != CheckAnswerText || len(ans.Checklist) != 2 || ans.Checklist[0].State != asks.StateSkipped {
		t.Fatalf("answer = %+v, want the fixed check text", ans)
	}
	var checkDone sql.NullString
	e.must(e.db.QueryRow(`SELECT check_done_at FROM watchman_items WHERE id = ?`, itemID).Scan(&checkDone))
	if checkDone.Valid || e.decideCalls() != 0 {
		t.Fatal("a check is never marked done by the twin, nor decided by the model")
	}
}

func TestTwin_HandoverContinueStartsSession(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.fileAsk(asks.KindQuestion, "Left: the CSV import", oneQuestion, "handover")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		d := decision(HandoverContinue)
		d.Category = "finish"
		return d, nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if got := e.decided[0]; got.Category != watchman.CategoryFinish || strings.Join(got.Options, "|") != strings.Join(HandoverOptions, "|") {
		t.Fatalf("Decide item = %+v", got)
	}
	if len(e.started) != 1 || e.started[0].workbench != e.wb || e.started[0].target != e.target || !strings.Contains(e.started[0].brief, "Left: the CSV import") {
		t.Fatalf("started = %+v, want one session on the target with the handover text", e.started)
	}
	if _, ans := e.askAnswer(askID); ans.Answers[0].Other != HandoverContinue {
		t.Fatalf("answer = %+v", ans)
	}
}

func TestTwin_HandoverAcceptAnswersOnly(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.fileAsk(asks.KindQuestion, "Left: nothing", oneQuestion, "handover")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) { return decision(HandoverAccept), nil }
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if len(e.started) != 0 {
		t.Fatalf("started = %+v, want none", e.started)
	}
}

func TestTwin_HandoverParkForMorning(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.fileAsk(asks.KindQuestion, "Left: the release", oneQuestion, "handover")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		d := decision(HandoverPark)
		d.Rationale = "the owner reviews schema changes himself"
		return d, nil
	}
	e.run()
	e.wantParked(askID, itemID, "the owner reviews schema changes himself")
	if len(e.started) != 0 {
		t.Fatal("a parked handover started a session")
	}
}

func TestTwin_SessionGoneJournalled(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.question("Which store?")
	e.port.mu.Lock()
	e.port.live = map[int64]bool{} // the session's process ended; its row is still live
	e.port.mu.Unlock()
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if it.Delivery != askanswer.DeliveryNoSession {
		t.Fatalf("delivery = %q, want no_session (journal: session ended)", it.Delivery)
	}
}

func TestTwin_AtMostTwoDeciding(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		e := newTwinEnv(t)
		e.question("One?")
		e.question("Two?")
		_, third := e.question("Three?")
		release := make(chan struct{})
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			<-release
			return decision("SQLite"), nil
		}
		ctx := context.Background()
		if n := e.twin.RunOnce(ctx); n != MaxDeciding {
			t.Fatalf("RunOnce = %d, want %d", n, MaxDeciding)
		}
		synctest.Wait()
		if n := e.twin.RunOnce(ctx); n != 0 {
			t.Fatalf("RunOnce while two decide = %d, want 0", n)
		}
		if it := e.item(third); it.State != "queued" {
			t.Fatalf("third item %s, want queued", it.State)
		}
		close(release)
		e.twin.Wait()
		if n := e.run(); n != 1 {
			t.Fatalf("RunOnce after = %d, want 1", n)
		}
	})
}

func TestTwin_UnmappableReplyParks(t *testing.T) {
	e := newTwinEnv(t)
	payload := `{"questions":[{"id":"a","question":"Which store?","options":[{"label":"SQLite"},{"label":"Files"}]},` +
		`{"id":"b","question":"Which format?","options":[{"label":"CSV"},{"label":"JSON"}]}]}`
	askID, itemID := e.fileAsk(asks.KindQuestion, "Two questions", payload, "ask")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return decision("SQLite and CSV"), nil
	}
	e.run()
	e.wantParkedTwo(askID, itemID, reasonUnmappable)
}

// wantParkedTwo is wantParked for an ask with two questions.
func (e *twinEnv) wantParkedTwo(askID, itemID int64, reason string) {
	e.t.Helper()
	it := e.item(itemID)
	wantOutcome(e.t, it, OutcomeParked)
	if it.ParkReason != reason {
		e.t.Fatalf("park reason = %q, want %q", it.ParkReason, reason)
	}
	_, ans := e.askAnswer(askID)
	if len(ans.Answers) != 2 || ans.Answers[1].Other != ParkedPrefix+reason {
		e.t.Fatalf("answer = %+v", ans)
	}
}

func TestAnswerFromDecision(t *testing.T) {
	two := asks.Payload{Questions: []asks.Question{
		{ID: "a", Question: "Which store?", Options: []asks.Option{{Label: "SQLite"}, {Label: "Files"}}},
		{ID: "b", Question: "Which store? Really", Options: []asks.Option{{Label: "Yes"}}},
	}}
	one := asks.Payload{Questions: two.Questions[:1]}
	multi := asks.Payload{Questions: []asks.Question{{ID: "m", Question: "Formats?", Multi: true, Options: []asks.Option{{Label: "CSV"}, {Label: "JSON"}}}}}
	cases := []struct {
		name   string
		p      asks.Payload
		choice string
		want   []asks.QuestionAnswer // nil = error
	}{
		{"option", one, "SQLite", []asks.QuestionAnswer{{ID: "a", Labels: []string{"SQLite"}}}},
		{"other", one, "Postgres", []asks.QuestionAnswer{{ID: "a", Labels: []string{}, Other: "Postgres"}}},
		{"multi labels", multi, "CSV, JSON", []asks.QuestionAnswer{{ID: "m", Labels: []string{"CSV", "JSON"}}}},
		{"per question", two, "- Which store?: Files\nWhich store? Really: maybe later", []asks.QuestionAnswer{
			{ID: "a", Labels: []string{"Files"}}, {ID: "b", Labels: []string{}, Other: "maybe later"}}},
		{"a question left out", two, "Which store?: Files", nil},
		{"a line naming no question", two, "Files\nWhich store? Really: Yes", nil},
		{"a question twice", two, "Which store?: Files\nWhich store?: SQLite\nWhich store? Really: Yes", nil},
		{"empty", one, " ", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := answerFromDecision(c.p, watchman.Decision{Choice: c.choice})
			if c.want == nil {
				if !errors.Is(err, errUnmappable) {
					t.Fatalf("err = %v, want errUnmappable", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			gotJSON, _ := json.Marshal(got.Answers)
			wantJSON, _ := json.Marshal(c.want)
			if string(gotJSON) != string(wantJSON) {
				t.Fatalf("answers = %s, want %s", gotJSON, wantJSON)
			}
		})
	}
}

type fakeLabeler struct {
	labels []watchman.Label
	err    error
	items  []watchman.LabelItem
}

func (f *fakeLabeler) Label(_ context.Context, items []watchman.LabelItem) ([]watchman.Label, error) {
	f.items = append(f.items, items...)
	return f.labels, f.err
}

func TestLabelParked_OnlyAFalseFlagClears(t *testing.T) {
	yes, no := true, false
	for _, c := range []struct {
		name   string
		labels []watchman.Label
		want   bool
	}{
		{"parked", []watchman.Label{{Parked: &yes}}, true},
		{"clear", []watchman.Label{{Parked: &no}}, false},
		{"no flag", []watchman.Label{{}}, true},
		{"no label", nil, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, reason, err := LabelParked(&fakeLabeler{labels: c.labels})(context.Background(), "Which store?")
			if err != nil || got != c.want || (got && reason == "") {
				t.Fatalf("LabelParked = %v, %q, %v; want %v with a reason", got, reason, err, c.want)
			}
		})
	}
	if _, _, err := LabelParked(&fakeLabeler{err: errors.New("down")})(context.Background(), "x"); err == nil {
		t.Fatal("a label error must reach the twin (it parks)")
	}
}

// replyGenerator answers every call with one reply and keeps the user messages.
type replyGenerator struct {
	reply string
	users []string
}

func (g *replyGenerator) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.users = append(g.users, user)
	return g.reply, nil, "", nil
}

func TestLiveDecide_CategorisesAQuestionFirst(t *testing.T) {
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	l := &fakeLabeler{labels: []watchman.Label{{Category: "design"}}}
	gen := &replyGenerator{reply: `{"choice":"SQLite","rationale":"r","precedent_ids":[],"confidence":"low","category":"design","importance":"low","handoff":"none"}`}
	dec, err := LiveDecide(context.Background(), d, gen, nil, l, watchman.Item{WorkbenchID: wb, Situation: "Which store?", Options: []string{"SQLite", "Files"}, DecidedBefore: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	if dec.Choice != "SQLite" || len(l.items) != 1 || !l.items[0].NeedCategory || len(gen.users) != 1 || !strings.Contains(gen.users[0], `"category":"design"`) {
		t.Fatalf("dec = %+v, label items %+v, users %q", dec, l.items, gen.users)
	}
	l.labels = []watchman.Label{{Category: "nonsense"}}
	if _, err := LiveDecide(context.Background(), d, gen, nil, l, watchman.Item{WorkbenchID: wb, Situation: "Which store?"}); err == nil {
		t.Fatal("an item with no usable category was decided")
	}
}

func TestTwin_SupersededAfterDecideKeepsChoice(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		// The agent files a newer ask while the model runs: this one is superseded.
		_, err := e.db.Exec(`UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'superseded' WHERE id = ?`, askID)
		e.must(err)
		return decision("SQLite"), nil
	}
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeSuperseded)
	if it.Choice != "SQLite" || e.port.delivered() != 0 {
		t.Fatalf("item = %+v, %d lines; want the choice kept, nothing delivered", it, e.port.delivered())
	}
}

func TestTwin_ShutdownNeverParksNorSpendsAnAttempt(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	_, err := e.db.Exec(`UPDATE watchman_items SET attempts = 2 WHERE id = ?`, itemID) // this is attempt 3
	e.must(err)
	ctx, cancel := context.WithCancel(context.Background())
	e.decideFn = func(ctx context.Context, _ watchman.Item) (watchman.Decision, error) {
		cancel() // the daemon stops mid-call
		<-ctx.Done()
		return watchman.Decision{}, ctx.Err()
	}
	if n := e.twin.RunOnce(ctx); n != 1 {
		t.Fatalf("RunOnce = %d", n)
	}
	e.twin.Wait()
	if it := e.item(itemID); it.State != "queued" || it.Attempts != 2 {
		t.Fatalf("item = %s/%d, want queued with attempt 3 given back", it.State, it.Attempts)
	}
	if status, _ := e.askAnswer(askID); status != "open" {
		t.Fatalf("ask = %s, want open (nothing written)", status)
	}
}

func TestTwin_HandoverStartRetriedAfterACrash(t *testing.T) {
	e := newTwinEnv(t)
	_, itemID := e.fileAsk(asks.KindQuestion, "Left: the CSV import", oneQuestion, "handover")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return decision(HandoverContinue), nil
	}
	fail := true
	e.twin.d.StartSession = func(_ context.Context, wb, target int64, brief string) error {
		e.mu.Lock()
		defer e.mu.Unlock()
		e.started = append(e.started, startCall{wb, target, brief})
		if fail {
			return errors.New("the process died before the start")
		}
		return nil
	}
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if it.Error != pendingStart {
		t.Fatalf("error = %q, want the owed start", it.Error)
	}
	fail = false
	e.run() // the next pass
	if len(e.started) != 2 || e.item(itemID).Error != "" {
		t.Fatalf("starts = %d, error %q; want the start retried and cleared", len(e.started), e.item(itemID).Error)
	}
	e.run()
	if len(e.started) != 2 {
		t.Fatal("a started session was started again")
	}
}

// finish_session makes the ask its handover while the twin decides it as a
// question: the answer is rolled back and the item decided again as a handover.
func TestTwin_HandoverMarkedWhileDecidingIsDecidedAsHandover(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Left: the CSV import")
	first := true
	e.decideFn = func(_ context.Context, it watchman.Item) (watchman.Decision, error) {
		if first {
			first = false
			_, _, err := e.db.PromoteWatchmanHandover(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session, RefID: askID, Question: "q"}, false)
			e.must(err)
			return decision("SQLite"), nil
		}
		return decision(HandoverAccept), nil
	}
	e.run()
	if it := e.item(itemID); it.State != "queued" || it.Attempts != 0 {
		t.Fatalf("item = %s/%d, want released", it.State, it.Attempts)
	}
	if status, _ := e.askAnswer(askID); status != "open" {
		t.Fatalf("ask = %s: answered as a question", status)
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if got := e.decided[1]; got.Category != watchman.CategoryFinish {
		t.Fatalf("second decision = %+v, want the handover path", got)
	}
}

func TestTwin_LateLabelAnswerStillParks(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		e := newTwinEnv(t)
		askID, itemID := e.question("Which store?")
		e.parkedFn = func(ctx context.Context, _ string) (bool, string, error) {
			<-ctx.Done()
			return false, "", nil // a "clear" that came after the timeout
		}
		e.run()
		e.wantParked(askID, itemID, reasonLabelFailed)
		if e.decideCalls() != 0 {
			t.Fatal("Decide ran after a late label answer")
		}
	})
}

func TestTwin_ParkWhoseAnswerKeepsFailingEndsParked(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Merge feature/x into main now?")
	_, err := e.db.Exec(`CREATE TRIGGER no_answers BEFORE UPDATE ON owner_asks BEGIN SELECT RAISE(ABORT, 'database is locked'); END`)
	e.must(err)
	for attempt := 1; attempt <= MaxAttempts; attempt++ {
		if n := e.run(); n != 1 {
			t.Fatalf("attempt %d: RunOnce = %d", attempt, n)
		}
	}
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeParked)
	if it.ParkReason != "a merge, push or rebase onto main" {
		t.Fatalf("park reason = %q", it.ParkReason)
	}
	if status, _ := e.askAnswer(askID); status != "open" {
		t.Fatalf("ask = %s, want open (the owner's)", status)
	}
	if n := e.run(); n != 0 {
		t.Fatal("a finished park was leased again")
	}
}

func TestTwin_OwnerFirstAfterAParkClearsIt(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Which store?")
	e.parkedFn = func(context.Context, string) (bool, string, error) {
		_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"answers":[{"id":"a","labels":["Files"],"other":""}]}', answered_at = '2026-11-18T08:00:00Z' WHERE id = ?`, askID)
		e.must(err)
		return true, "the label says the owner decides", nil
	}
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeOwnerFirst)
	if it.ParkReason != "" || it.Choice != "" || it.Rationale != "" {
		t.Fatalf("item = %+v, want the park cleared", it)
	}
}

func TestTwin_SummaryHardLimitParks(t *testing.T) {
	e := newTwinEnv(t)
	payload := `{"questions":[{"id":"a","question":"OK to proceed?","options":[{"label":"Yes"},{"label":"No"}]}]}`
	askID, itemID := e.fileAsk(asks.KindQuestion, "Release prep", payload, "ask")
	_, err := e.db.Exec(`UPDATE owner_asks SET summary = 'I''ll merge this into main' WHERE id = ?`, askID)
	e.must(err)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) { return decision("Yes"), nil }
	e.run()
	e.wantParked(askID, itemID, "a merge, push or rebase onto main")
}

// continueEnv is an armed env whose handover the twin continues, with a
// scripted session start.
func continueEnv(t *testing.T, start func() error) (*twinEnv, int64) {
	e := newTwinEnv(t)
	_, itemID := e.fileAsk(asks.KindQuestion, "Left: the CSV import", oneQuestion, "handover")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return decision(HandoverContinue), nil
	}
	e.twin.d.StartSession = func(_ context.Context, wb, target int64, brief string) error {
		e.mu.Lock()
		e.started = append(e.started, startCall{wb, target, brief})
		e.mu.Unlock()
		return start()
	}
	return e, itemID
}

func (e *twinEnv) startCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.started)
}

func TestTwin_HandoverStartTwoPassesNeverStartTwice(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		e, itemID := continueEnv(t, func() error { <-release; return nil })
		ctx := context.Background()
		e.twin.RunOnce(ctx)
		synctest.Wait() // the start runs (claimed)
		e.twin.RunOnce(ctx)
		e.twin.RunOnce(ctx)
		if n := e.startCount(); n != 1 {
			t.Fatalf("starts = %d while the first runs, want 1", n)
		}
		close(release)
		e.twin.Wait()
		e.run()
		if n, err := e.startCount(), e.item(itemID).Error; n != 1 || err != "" {
			t.Fatalf("starts = %d, error %q", n, err)
		}
	})
}

func TestTwin_HandoverStartClaimedAtACrashIsNotRetried(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return nil })
	e.run()
	// As if the daemon died between the claim and the start's answer.
	_, err := e.db.Exec(`UPDATE watchman_items SET error = ? WHERE id = ?`, startingMark, itemID)
	e.must(err)
	e.run()
	if n := e.startCount(); n != 1 || e.item(itemID).Error != mayHaveStarted {
		t.Fatalf("starts = %d, error %q; want no second start and the check-the-workbench error", n, e.item(itemID).Error)
	}
}

func TestTwin_HandoverStartStopsWhenDisarmed(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return errors.New("host busy") })
	e.run()
	if e.item(itemID).Error != pendingStart {
		t.Fatalf("error = %q", e.item(itemID).Error)
	}
	e.finishSession()
	e.prune()
	e.disarm() // Take back deletes the row the prune kept
	e.run()
	if n := e.startCount(); n != 1 || e.item(itemID).Error != startTakenBack {
		t.Fatalf("starts = %d, error %q; want no start after Take back", n, e.item(itemID).Error)
	}
}

func TestTwin_HandoverStartGivesUpAfterMaxAttempts(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return errors.New("host busy") })
	for range MaxAttempts + 2 {
		e.run()
	}
	if n := e.startCount(); n != MaxAttempts {
		t.Fatalf("starts = %d, want %d", n, MaxAttempts)
	}
	if got := e.item(itemID).Error; got != startFailedPrefix+"host busy" {
		t.Fatalf("error = %q", got)
	}
}

func TestTwin_OwnerFirstOnAContinueOwesNoStart(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return nil })
	askID := int64(0)
	e.must(e.db.QueryRow(`SELECT ref_id FROM watchman_items WHERE id = ?`, itemID).Scan(&askID))
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"answers":[{"id":"a","labels":["SQLite"],"other":""}]}', answered_at = '2026-11-18T08:00:00Z' WHERE id = ?`, askID)
		e.must(err)
		return decision(HandoverContinue), nil
	}
	e.run()
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeOwnerFirst)
	if it.Error != "" || e.startCount() != 0 {
		t.Fatalf("error = %q, starts %d; want no start owed", it.Error, e.startCount())
	}
}

// finishSession ends the env's session as finish_session's exit does.
func (e *twinEnv) finishSession() {
	_, err := e.db.Exec(`UPDATE terminal_sessions SET finished_at = ? WHERE id = ?`, db.AgentStateStamp(time.Now()), e.session)
	e.must(err)
	e.port.mu.Lock()
	delete(e.port.live, e.session)
	e.port.mu.Unlock()
}

// prune is the daemon upkeep's arming prune.
func (e *twinEnv) prune() {
	_, err := e.db.PruneWatchmanArming()
	e.must(err)
}

// The main path: the session finishes, upkeep prunes, the first start fails
// — the next pass still starts the next session (the arming row is kept).
func TestTwin_HandoverStartSurvivesFinishAndPrune(t *testing.T) {
	fail := true
	e, itemID := continueEnv(t, func() error {
		if fail {
			return errors.New("host busy")
		}
		return nil
	})
	e.run()
	e.finishSession()
	e.prune()
	fail = false
	e.run()
	if n, got := e.startCount(), e.item(itemID).Error; n != 2 || got != "" {
		t.Fatalf("starts = %d, error %q; want the second start after finish and prune", n, got)
	}
	e.prune()
	var left int
	e.must(e.db.QueryRow(`SELECT COUNT(*) FROM watchman_arming WHERE scope = 'session' AND ref_id = ?`, e.session).Scan(&left))
	if left != 0 {
		t.Fatal("the arming row outlived the handover")
	}
}

// A handover still queued when its session finished is leased and decided.
func TestTwin_HandoverQueuedAtFinishIsDecided(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return nil })
	e.finishSession()
	e.prune()
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want the handover leased", n)
	}
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if e.startCount() != 1 {
		t.Fatalf("starts = %d", e.startCount())
	}
}

// A Take back between the arming check and the claim: the claim's own
// arming check refuses it, nothing starts.
func TestTwin_HandoverStartDisarmBeforeClaim(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return nil })
	prev := beforeStartClaim
	beforeStartClaim = func() { e.disarm() }
	t.Cleanup(func() { beforeStartClaim = prev })
	e.run()
	if n, got := e.startCount(), e.item(itemID).Error; n != 0 || got != startTakenBack {
		t.Fatalf("starts = %d, error %q; want none, taken back", n, got)
	}
}

// A pass that claims, starts and clears the start while the answer's line is
// typed: the delivery note does not bring the owed start back.
func TestTwin_DeliveryNoteKeepsAStartDone(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return nil })
	e.port.mu.Lock()
	e.port.onDeliver = func() { e.twin.retryStarts(context.Background()) }
	e.port.mu.Unlock()
	e.run()
	e.run()
	if n, got := e.startCount(), e.item(itemID).Error; n != 1 || got != "" {
		t.Fatalf("starts = %d, error %q; want one start", n, got)
	}
}

// A deleted session's arming row is pruned even with a start owed: the start
// ends taken back, nothing starts.
func TestTwin_HandoverStartOfADeletedSessionIsTakenBack(t *testing.T) {
	e, itemID := continueEnv(t, func() error { return errors.New("host busy") })
	e.run()
	_, err := e.db.Exec(`UPDATE terminal_sessions SET finished_at = ?, delete_requested_at = ? WHERE id = ?`,
		db.AgentStateStamp(time.Now()), db.AgentStateStamp(time.Now()), e.session)
	e.must(err)
	e.prune()
	e.run()
	if n, got := e.startCount(), e.item(itemID).Error; n != 1 || got != startTakenBack {
		t.Fatalf("starts = %d, error %q; want no second start, taken back", n, got)
	}
}

// targetOnlyEnv arms target A only (the session's), with the handover ask
// naming dest; the session is not armed directly.
func targetOnlyEnv(t *testing.T, dest func(e *twinEnv) int64) (*twinEnv, int64) {
	e := newTwinEnv(t)
	e.disarm()
	e.must(e.db.UpsertWatchmanArming(db.WatchmanArming{Scope: "target", RefID: e.target, ArmedAt: time.Now(), ArmedBy: "cli"}))
	askID, itemID := e.fileAsk(asks.KindQuestion, "Left: the CSV import", oneQuestion, "handover")
	to := dest(e)
	_, err := e.db.Exec(`UPDATE owner_asks SET target_id = ? WHERE id = ?`, to, askID)
	e.must(err)
	_, err = e.db.Exec(`UPDATE watchman_items SET target_id = ? WHERE id = ?`, to, itemID)
	e.must(err)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return decision(HandoverContinue), nil
	}
	return e, itemID
}

func newTarget(e *twinEnv, text string) int64 {
	res, err := e.db.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES (?, 'custom', 'project', '2026-11-18', '2026-11-18', 'chat', ?)`, text, e.wb)
	e.must(err)
	id, _ := res.LastInsertId()
	return id
}

// The source session's armed target A lets the twin decide the handover,
// but not start a session on target B nobody handed to Watchman.
func TestTwin_HandoverStartNeedsTheDestinationArmed(t *testing.T) {
	e, itemID := targetOnlyEnv(t, func(e *twinEnv) int64 { return newTarget(e, "B") })
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want the handover leased through A", n)
	}
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeAnswered)
	if e.startCount() != 0 || it.Error != startTakenBack {
		t.Fatalf("starts = %d, error %q; want no start on B", e.startCount(), it.Error)
	}
}

// A session being deleted lends no coverage: its owed start (destination
// unarmed, coverage only through the session's target) ends taken back.
func TestTwin_HandoverStartOfADeletingSessionViaTargetIsTakenBack(t *testing.T) {
	var dest int64
	e, itemID := targetOnlyEnv(t, func(e *twinEnv) int64 { dest = newTarget(e, "B"); return dest })
	_, err := e.db.Exec(`UPDATE watchman_arming SET ref_id = ? WHERE scope = 'target'`, dest) // B armed for the decision
	e.must(err)
	fail := true
	e.twin.d.StartSession = func(context.Context, int64, int64, string) error {
		e.mu.Lock()
		e.started = append(e.started, startCall{})
		e.mu.Unlock()
		if fail {
			return errors.New("host busy")
		}
		return nil
	}
	e.run()
	if e.item(itemID).Error != pendingStart {
		t.Fatalf("error = %q", e.item(itemID).Error)
	}
	// B taken back, A armed again: only the deleting session's target is left.
	_, err = e.db.Exec(`UPDATE watchman_arming SET ref_id = ? WHERE scope = 'target'`, e.target)
	e.must(err)
	_, err = e.db.Exec(`UPDATE terminal_sessions SET finished_at = ?, delete_requested_at = ? WHERE id = ?`,
		db.AgentStateStamp(time.Now()), db.AgentStateStamp(time.Now()), e.session)
	e.must(err)
	fail = false
	e.run()
	if n, got := e.startCount(), e.item(itemID).Error; n != 1 || got != startTakenBack {
		t.Fatalf("starts = %d, error %q; want taken back", n, got)
	}
}

// promoteHandover is finish_session's promotion of ask askID, held while
// the review gate refuses, released once a finish passes.
func (e *twinEnv) promoteHandover(askID int64, held bool) {
	e.t.Helper()
	_, _, err := e.db.PromoteWatchmanHandover(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session, TargetID: e.target,
		RefID: askID, Question: "Left: the CSV import"}, held)
	e.must(err)
}

func continueDecision(context.Context, watchman.Item) (watchman.Decision, error) {
	d := decision(HandoverContinue)
	d.Category = watchman.CategoryFinish
	return d, nil
}

// Final review B-I1: the handover ask of a finish the review gate refuses is
// the handover at once, held — the twin decides nothing, not as a question
// either; once the review approves and a finish passes, it is decided as the
// handover and Continue starts the next session.
func TestTwin_HandoverHeldUntilTheFinishPasses(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Left: the CSV import")
	e.promoteHandover(askID, true) // finish_session refused by the review gate
	if n := e.run(); n != 0 || e.decideCalls() != 0 {
		t.Fatalf("RunOnce = %d, decisions %d; want the held handover left alone", n, e.decideCalls())
	}
	if it := e.item(itemID); it.State != "queued" || it.Error != db.WatchmanHandoverHeld {
		t.Fatalf("item = %s/%q, want queued and held", it.State, it.Error)
	}
	if status, _ := e.askAnswer(askID); status != "open" {
		t.Fatalf("ask = %s, want open", status)
	}
	e.promoteHandover(askID, true) // refused again
	e.run()
	if e.decideCalls() != 0 {
		t.Fatal("decided while held")
	}

	e.decideFn = continueDecision
	e.promoteHandover(askID, false) // the review approved: the finish passes
	e.finishSession()
	if n := e.run(); n != 1 {
		t.Fatalf("RunOnce = %d, want the handover leased", n)
	}
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	if got := e.decided[0]; got.Category != watchman.CategoryFinish {
		t.Fatalf("decision = %+v, want the handover path", got)
	}
	if e.startCount() != 1 {
		t.Fatalf("starts = %d, want the next session", e.startCount())
	}
	if _, ans := e.askAnswer(askID); ans.Answers[0].Other != HandoverContinue {
		t.Fatalf("answer = %+v", ans)
	}
}

// A held handover the twin was deciding as a question when it was promoted:
// released (kind changed), it stays held after a failed attempt's requeue.
func TestTwin_RequeueKeepsTheHold(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Left: the CSV import")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		e.promoteHandover(askID, true)
		return watchman.Decision{}, errors.New("model hiccup")
	}
	e.run()
	if it := e.item(itemID); it.State != "queued" || it.Error != db.WatchmanHandoverHeld {
		t.Fatalf("item = %s/%q, want queued and still held", it.State, it.Error)
	}
	if n := e.run(); n != 0 {
		t.Fatalf("RunOnce = %d, want nothing leased", n)
	}
}

// The twin answered the ask as a question before finish_session named it
// the handover: a handover row joins it, decided without answering the ask
// again; the earlier answer stays in the journal.
func TestTwin_HandoverOfAnAskTheTwinAnswered(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Left: the CSV import")
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeAnswered)
	_, before := e.askAnswer(askID)
	e.promoteHandover(askID, true)
	h, err := e.db.WatchmanItemByRef("ask", askID, "handover")
	e.must(err)
	if h == nil || h.State != "queued" || h.Error != db.WatchmanHandoverHeld {
		t.Fatalf("handover = %+v, want a held row beside the answered question", h)
	}
	if n := e.run(); n != 0 {
		t.Fatal("a held handover was leased")
	}
	e.decideFn = continueDecision
	e.promoteHandover(askID, false)
	e.run()
	wantOutcome(t, e.item(h.ID), OutcomeAnswered)
	if e.startCount() != 1 {
		t.Fatalf("starts = %d, want the next session", e.startCount())
	}
	if _, after := e.askAnswer(askID); !reflect.DeepEqual(after, before) {
		t.Fatalf("ask answer = %+v, want the earlier %+v", after, before)
	}
	if first := e.item(itemID); first.Outcome != OutcomeAnswered || first.Choice != "SQLite" {
		t.Fatalf("earlier item = %+v, want it kept", first)
	}
}

// An ask the owner answered (no twin answer) gets no handover: nothing to
// decide in his place.
func TestTwin_HandoverOfAnOwnerAnsweredAskIsNotQueued(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.question("Left: the CSV import")
	_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"answers":[]}' WHERE id = ?`, askID)
	e.must(err)
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	e.promoteHandover(askID, false)
	if h, err := e.db.WatchmanItemByRef("ask", askID, "handover"); err != nil || h != nil {
		t.Fatalf("handover = %+v, %v; want none", h, err)
	}
}

// Final review B-I2: a decision that ends wakes the caller, so a third item
// left queued behind MaxDeciding is decided on that wake, not at the next
// cycle; an item put back until later asks for a wake when it comes due.
func TestTwin_FreedSlotWakesTheNextPass(t *testing.T) {
	e := newTwinEnv(t)
	var wakes int
	var mu sync.Mutex
	e.twin.d.Wake = func() { mu.Lock(); wakes++; mu.Unlock() }
	var ids []int64
	for _, title := range []string{"Which store?", "Which cache?", "Which queue?"} {
		_, id := e.question(title)
		ids = append(ids, id)
	}
	if n := e.run(); n != MaxDeciding {
		t.Fatalf("RunOnce = %d, want %d", n, MaxDeciding)
	}
	if it := e.item(ids[2]); it.State != "queued" {
		t.Fatalf("third item = %s, want queued behind the two", it.State)
	}
	mu.Lock()
	got := wakes
	mu.Unlock()
	if got != MaxDeciding {
		t.Fatalf("wakes = %d, want one per ended decision", got)
	}
	e.run() // the pass the wake asks for
	wantOutcome(t, e.item(ids[2]), OutcomeAnswered)

	// A provider refusal puts the item back for ProviderRetry: a wake is
	// scheduled for then.
	var after []time.Duration
	e.twin.d.After = func(d time.Duration, f func()) { after = append(after, d); f() }
	_, id := e.question("Which index?")
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return watchman.Decision{}, &providers.Failure{Category: providers.Quota}
	}
	e.run()
	if it := e.item(id); it.State != "queued" || len(after) != 1 || after[0] <= 0 || after[0] > ProviderRetry {
		t.Fatalf("item %s, scheduled %v; want queued with one wake within ProviderRetry", it.State, after)
	}
}
