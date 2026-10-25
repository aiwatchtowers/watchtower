package automations_test

import (
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// A waiting run survives a daemon restart (AUTO-08 as amended by board
// #795): the stop leaves it waiting, the next start replays its script
// against its log and re-enters the same wait.

const resumeAskCall = `ask({kind: "question", title: "Ship it?",
	questions: [{question: "Ship it?", options: [{label: "Yes"}, {label: "No"}]}]})`

// stopWhileWaiting runs the executor until run id waits, then stops it (the
// daemon stopping) and checks the run stayed waiting.
func (f *exFixture) stopWhileWaiting(t *testing.T, id int64) {
	t.Helper()
	stop := runExecutor(t, f)
	f.waitStatus(t, id, db.RunWaiting)
	stop()
	if r := f.run(t, id); r.Status != db.RunWaiting || r.FinishedAt != nil {
		t.Fatalf("run %d after the stop = %s/%s (%s); want still waiting", id, r.Status, r.ErrorKind, r.Error)
	}
}

// waitEnded waits (real time) until run id is no longer active.
func (f *exFixture) waitEnded(t *testing.T, id int64) *db.AutomationRun {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		r := f.run(t, id)
		if r.Status != db.RunQueued && r.Status != db.RunRunning && r.Status != db.RunWaiting {
			return r
		}
		if time.Now().After(deadline) {
			t.Fatalf("run %d never ended (is %s/%s)", id, r.Status, r.WaitingReason)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// replayRows counts run id's replay log.
func (f *exFixture) replayRows(t *testing.T, id int64) int {
	t.Helper()
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM automation_run_replay WHERE run_id = ?`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// answerAsk plays the Desktop's answer to ask id.
func (w *writeFixture) answerAsk(t *testing.T, id int64) {
	t.Helper()
	if _, err := w.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?,
		answered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND status = 'open'`,
		`{"answers":[{"id":"1","labels":["Yes"]}]}`, id); err != nil {
		t.Fatal(err)
	}
}

func stepSeqsAndKinds(steps []db.AutomationRunStep) string {
	parts := make([]string, len(steps))
	for i, s := range steps {
		parts[i] = strconv.Itoa(s.Seq) + ":" + s.Kind + ":" + s.Status
	}
	return strings.Join(parts, ",")
}

// TestAuto08_ResumeAtAskWait: the stop leaves the run waiting with its ask
// open; the restart replays log/state/output (no new step, no new ask),
// waits on the same ask, and the answer finishes the run, which then commits
// the state and output its replay re-buffered (AUTO-04) — one step per call
// across both daemon lives (AUTO-11).
func TestAuto08_ResumeAtAskWait(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox",
		`log("before"); state.set("k", "v"); output.inbox({title: "filed", body: "b"});
		const r = `+resumeAskCall+`; return JSON.stringify(r)`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	ask := w.onlyAsk(t, a.ProjectID)
	if ask.Status != "open" {
		t.Fatalf("ask after the stop = %s; want open (not withdrawn)", ask.Status)
	}
	if got := w.dump(t); got != "" {
		t.Fatalf("committed before the run ended: %q", got)
	}
	if n := w.replayRows(t, id); n != 4 {
		t.Fatalf("replay rows = %d; want 4 (three calls and the pending wait)", n)
	}

	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	if list := w.asksOf(t, a.ProjectID); len(list) != 1 {
		t.Fatalf("asks after the resume = %d; want the one ask", len(list))
	}
	w.answerAsk(t, ask.ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	mustContain(t, "summary", r.Summary, `"labels":["Yes"]`)
	if got := stepSeqsAndKinds(w.steps(t, id)); got != "1:log:ok,2:state:ok,3:output:ok,4:ask:ok" {
		t.Fatalf("steps = %s; want each call once", got)
	}
	if s := w.askStep(t, id); s.AskID != ask.ID {
		t.Fatalf("ask step links ask %d; want %d", s.AskID, ask.ID)
	}
	dump := w.dump(t)
	if !strings.Contains(dump, `{"k":"v"}`) || strings.Count(dump, "|inbox|filed|b|") != 1 {
		t.Fatalf("committed = %q; want the state and the one output", dump)
	}
	if n := w.replayRows(t, id); n != 0 {
		t.Fatalf("replay rows after the finish = %d; want 0", n)
	}
	mustContain(t, "log", w.logs.String(), "run "+strconv.FormatInt(id, 10)+" resumed after restart (replayed 3 steps)")
}

// TestAuto08_ResumeAtApprovalWait: a tool {wait} survives the restart and
// waits on the same proposal; no second proposal is made.
func TestAuto08_ResumeAtApprovalWait(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWrite(t, []string{"tool:create_target"}, "", waitScript)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	action := w.onlyAction(t)
	if action.Status != "pending" {
		t.Fatalf("action = %s; want pending", action.Status)
	}
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.approveAndApply(t, action.ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded || summaryObject(t, r)["status"] != "applied" {
		t.Fatalf("run = %s (%s) %s; want succeeded with the applied write", r.Status, r.Error, r.Summary)
	}
	if rows := w.actions(t); len(rows) != 1 {
		t.Fatalf("agent_actions = %d; want the one proposal", len(rows))
	}
	if s := w.toolStep(t, id); s.Status != automations.StepApplied || s.ActionID != action.ID {
		t.Fatalf("tool step = %s action %d; want applied, linked to %d", s.Status, s.ActionID, action.ID)
	}
}

// TestAuto08_ResumeAtSessionWait: a session() survives the restart and keeps
// waiting on the session the Desktop launched.
func TestAuto08_ResumeAtSessionWait(t *testing.T) {
	s := newSessFixture(t, "claude")
	a := s.seedSession(t, []string{"session:start"}, "", sessScript)
	id := s.enqueue(t, a, db.TriggerManual)
	stop := runExecutor(t, s.exFixture)
	s.waitReason(t, id, db.WaitApp)
	sess := s.launch(t, id, s.sessionStep(t, id).ID)
	s.waitReason(t, id, db.WaitSession)
	stop()
	s.wantRun(t, id, db.RunWaiting, "")

	s.restart()
	stop = runExecutor(t, s.exFixture)
	defer stop()
	s.waitReason(t, id, db.WaitSession)
	s.setSession(t, sess, `finished_at = '2026-10-14T12:30:00.000Z', finish_summary = 'Two findings filed'`)
	s.e.Wake()
	r := s.waitEnded(t, id)
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	checkFinishedSession(t, summaryObject(t, r), sess)
	if got := stepSeqsAndKinds(s.steps(t, id)); got != "1:session:ok" {
		t.Fatalf("steps = %s; want the one session step", got)
	}
}

// externalModule defines external(): a value from outside the journal (a
// test-only call that writes no step), so a replay can see a different one.
func externalModule(v *atomic.Int64) automations.Module {
	return externalModuleCounting(v, new(atomic.Int64))
}

// externalModuleCounting is externalModule that also counts its calls in
// reads, so a test knows the script runs (its meter started).
func externalModuleCounting(v, reads *atomic.Int64) automations.Module {
	return exModule{name: "external", fns: map[string]automations.SDKFunc{
		"external": func(*automations.Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			reads.Add(1)
			return v.Load(), nil
		},
	}}
}

// TestAuto08_DivergenceEndsTheRunWithoutExecuting: a resumed script that
// makes a different call than its log ends failed/script; nothing it
// replayed runs again (no second proposal, no second ask) and its open ask
// is withdrawn.
func TestAuto08_DivergenceEndsTheRunWithoutExecuting(t *testing.T) {
	var v atomic.Int64
	w := newWriteFixtureWith(t, func(*exFixture) []automations.Module { return []automations.Module{externalModule(&v)} })
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner", "tool:create_target"}, "inbox",
		`tool("create_target", {text: "Reply to acme"}); log("v" + external()); `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	ask := w.onlyAsk(t, a.ProjectID)

	v.Store(1) // the script will log a different value
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	r := w.waitEnded(t, id)
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindScript ||
		r.Error != "the recipe ran differently after the restart (step 2); it was not resumed" {
		t.Fatalf("run = %s/%s (%s); want failed/script naming step 2", r.Status, r.ErrorKind, r.Error)
	}
	if rows := w.actions(t); len(rows) != 1 {
		t.Fatalf("agent_actions = %d; want the one proposal of the first life", len(rows))
	}
	if got := stepSeqsAndKinds(w.steps(t, id)); got != "1:tool:proposed,2:log:ok,3:ask:error" {
		t.Fatalf("steps = %s; want the first life's steps only", got)
	}
	w.e.Wake() // the next poll withdraws the ended run's ask
	deadline := time.Now().Add(10 * time.Second)
	for got := w.onlyAsk(t, a.ProjectID); got.Status != "withdrawn"; got = w.onlyAsk(t, a.ProjectID) {
		if time.Now().After(deadline) {
			t.Fatalf("ask %d = %s; want withdrawn after the divergence", ask.ID, got.Status)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestAuto08_ChangedRecipeIsNotResumed: a recipe re-confirmed at another
// hash while the daemon was down is not resumed: the start ends its run as
// before and withdraws its ask.
func TestAuto08_ChangedRecipeIsNotResumed(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", `log("a"); `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	ask := w.onlyAsk(t, a.ProjectID)
	if _, err := w.d.Exec(`UPDATE automations SET approval_hash = 'h-new', confirmed_hash = 'h-new' WHERE id = ?`, a.ID); err != nil {
		t.Fatal(err)
	}
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	r := w.waitEnded(t, id)
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindInterrupted {
		t.Fatalf("run = %s/%s (%s); want failed/interrupted", r.Status, r.ErrorKind, r.Error)
	}
	w.e.Wake()
	deadline := time.Now().Add(10 * time.Second)
	for got := w.onlyAsk(t, a.ProjectID); got.Status != "withdrawn"; got = w.onlyAsk(t, a.ProjectID) {
		if time.Now().After(deadline) {
			t.Fatalf("ask %d = %s; want withdrawn", ask.ID, got.Status)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := stepSeqsAndKinds(w.steps(t, id)); got != "1:log:ok,2:ask:error" {
		t.Fatalf("steps = %s; want nothing replayed", got)
	}
}

// TestAuto08_LargeResultMakesTheRunNotResumable: a call whose result is past
// the replay cap flags the run, and a stop while it waits ends it as before.
func TestAuto08_LargeResultMakesTheRunNotResumable(t *testing.T) {
	prev := automations.MaxReplayResultBytes
	automations.MaxReplayResultBytes = 3 // `"done"` is 6 bytes
	t.Cleanup(func() { automations.MaxReplayResultBytes = prev })
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner", "llm:light"}, "inbox", `llm("x"); `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	stop := runExecutor(t, w.exFixture)
	w.waitStatus(t, id, db.RunWaiting)
	if !w.run(t, id).NotResumable {
		t.Fatal("the run is not flagged not resumable after a result past the cap")
	}
	stop()
	w.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
}

// TestAuto08_TimeAndRandomReplay: Date.now(), new Date() and Math.random
// give the resumed script the values its first life read, so the calls it
// made with them match their log.
func TestAuto08_TimeAndRandomReplay(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox",
		`const t = Date.now(), d = new Date().getTime(), x = Math.random();
		log(t + "|" + d + "|" + x); `+resumeAskCall+`; return t + "|" + d + "|" + x`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	logged := w.steps(t, id)[0].ArgsJSON
	time.Sleep(20 * time.Millisecond) // the real clock moves on
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, w.onlyAsk(t, a.ProjectID).ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded || r.Summary != logged {
		t.Fatalf("run = %s (%s) summary %q; want succeeded returning the logged %q", r.Status, r.Error, r.Summary, logged)
	}
}

// TestAuto08_ResumedTokensNotDoubleCounted: a replayed llm() call neither
// calls the model again nor adds its tokens a second time.
func TestAuto08_ResumedTokensNotDoubleCounted(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner", "llm:light"}, "inbox", `llm("x"); `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, w.onlyAsk(t, a.ProjectID).ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded || r.InputTokens != 10 || r.OutputTokens != 5 {
		t.Fatalf("run = %s tokens %d+%d; want succeeded with 10+5 once", r.Status, r.InputTokens, r.OutputTokens)
	}
	if n := fakeGenCalls(t, w.gen); n != 1 {
		t.Fatalf("model calls = %d; want 1", n)
	}
}

// TestAuto08_StopWhileRunningStillInterrupts: a run inside a call (not
// waiting) when the daemon stops still ends failed/interrupted, and the
// next start does not resume it.
func TestAuto08_StopWhileRunningStillInterrupts(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	id := f.enqueue(t, f.seed(t, "digest", `log("a"); llm("x"); return 1`, false), db.TriggerManual)
	stop := runExecutor(t, f)
	gen.waitEntered(t)
	stop()
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
	mustContain(t, "error", r.Error, "the daemon stopped")
	if n := f.replayRows(t, id); n != 0 {
		t.Fatalf("replay rows = %d; want none after the end", n)
	}
	f.restart()
	if err := f.e.Run(cancelledCtx()); err != nil {
		t.Fatal(err)
	}
	f.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
	if got := stepSeqsAndKinds(f.steps(t, id)); got != "1:log:ok,2:llm:error" {
		t.Fatalf("steps = %s", got)
	}
}

// TestAuto08_ResumedWaitKeepsItsPauseTimeout: pause_timeout_hours counts
// from the original wait, so time the daemon was down counts.
func TestAuto08_ResumedWaitKeepsItsPauseTimeout(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	w.clock.Advance(73 * time.Hour) // past the default 72 hours, all of it while the daemon was down
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	r := w.waitEnded(t, id)
	if r.Status != db.RunExpired || r.ErrorKind != db.ErrKindExpired {
		t.Fatalf("run = %s/%s (%s); want expired", r.Status, r.ErrorKind, r.Error)
	}
}

// TestAuto08_ResumeAfterAgent: agent()'s step records a budget carved from
// what the run had left, which differs once the meter carries the first
// life's spend; the replay checks what the script asked, so the run resumes
// and the agent runs once.
func TestAuto08_ResumeAfterAgent(t *testing.T) {
	agent := &automationstest.FakeAgent{ModelCalls: [][2]int{{10, 5}}, Result: automations.AgentResult{Text: "triaged"}}
	w := newWriteFixtureOpts(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) { b.Agent = agent }})
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner", "agent:run", "llm:light"}, "inbox",
		`agent("triage the inbox"); `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, w.onlyAsk(t, a.ProjectID).ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	if got := stepSeqsAndKinds(w.steps(t, id)); got != "1:agent:ok,2:ask:ok" {
		t.Fatalf("steps = %s; want each call once", got)
	}
	if n := len(agent.Requests()); n != 1 {
		t.Fatalf("agent runs = %d; want 1", n)
	}
}

// TestAuto08_ResumeAfterDefaultAgentChanged: a session() without its own
// agent resolved the workbench default; a default changed while the run
// waited neither diverges the replay nor changes the session it waits on.
func TestAuto08_ResumeAfterDefaultAgentChanged(t *testing.T) {
	s := newSessFixture(t, "claude")
	a := s.seedSession(t, []string{"session:start"}, "", sessScript)
	id := s.enqueue(t, a, db.TriggerManual)
	stop := runExecutor(t, s.exFixture)
	s.waitReason(t, id, db.WaitApp)
	sess := s.launch(t, id, s.sessionStep(t, id).ID)
	s.waitReason(t, id, db.WaitSession)
	stop()
	s.agent = "codex"
	s.restart()
	stop = runExecutor(t, s.exFixture)
	defer stop()
	s.waitReason(t, id, db.WaitSession)
	s.setSession(t, sess, `finished_at = '2026-10-14T12:30:00.000Z', finish_summary = 'Two findings filed'`)
	s.e.Wake()
	r := s.waitEnded(t, id)
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	if st := s.sessionStep(t, id); !strings.Contains(st.ArgsJSON, `"agent":"claude"`) || st.Name != "claude" {
		t.Fatalf("session step = %s %s; want the agent it started with", st.Name, st.ArgsJSON)
	}
}

// loopScript waits on an ask after a log; once external() is non-zero (set
// before the restart) the replay spins between the two, so a test can act
// while the replay has not reached the wait.
const loopScript = `log("a"); if (external() > 0) { while (true) {} } ` + resumeAskCall + `; return 1`

// TestAuto08_StopDuringReplayReturnsToWaiting: a daemon stop before the
// replay reached the wait puts the run back to waiting (its ask open, this
// life's active time recorded), and the next start resumes it.
func TestAuto08_StopDuringReplayReturnsToWaiting(t *testing.T) {
	var v, reads atomic.Int64
	w := newWriteFixtureWith(t, func(*exFixture) []automations.Module {
		return []automations.Module{externalModuleCounting(&v, &reads)}
	})
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", loopScript)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	before := w.run(t, id).ActiveMS
	v.Store(1)
	w.restart()
	readsBefore := reads.Load()
	stop := runExecutor(t, w.exFixture)
	// The claim marks the run running before its meter starts; the clock
	// moves only once the replayed script calls external() (meter running).
	deadline := time.Now().Add(10 * time.Second)
	for reads.Load() == readsBefore {
		if time.Now().After(deadline) {
			t.Fatalf("the resumed script never ran (run is %s)", w.run(t, id).Status)
		}
		time.Sleep(5 * time.Millisecond)
	}
	w.clock.Advance(30 * time.Second)
	stop()
	r := w.wantRun(t, id, db.RunWaiting, "")
	if r.WaitingReason != db.WaitAsk || r.ActiveMS < before+30000 {
		t.Fatalf("run = reason %q active_ms %d (was %d); want ask and 30 s more", r.WaitingReason, r.ActiveMS, before)
	}
	ask := w.onlyAsk(t, a.ProjectID)
	if ask.Status != "open" {
		t.Fatalf("ask = %s; want open", ask.Status)
	}
	v.Store(0)
	w.restart()
	stop = runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, ask.ID)
	w.e.Wake()
	if r := w.waitEnded(t, id); r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
}

// TestAuto08_DeadlineDuringReplayKeepsItsEnd: a resumed run whose carried
// active time already spent its budget ends timed_out, not as a divergence.
func TestAuto08_DeadlineDuringReplayKeepsItsEnd(t *testing.T) {
	var v atomic.Int64
	w := newWriteFixtureWith(t, func(*exFixture) []automations.Module { return []automations.Module{externalModule(&v)} })
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", loopScript)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	if err := w.d.AddAutomationRunUsage(id, db.RunUsage{ActiveMS: (6 * time.Minute).Milliseconds()}); err != nil {
		t.Fatal(err) // past the 5-minute budget
	}
	v.Store(1)
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	if r := w.waitEnded(t, id); r.Status != db.RunTimedOut || r.ErrorKind != db.ErrKindTimeout {
		t.Fatalf("run = %s/%s (%s); want timed_out/timeout", r.Status, r.ErrorKind, r.Error)
	}
}

// TestAuto08_ClockReadOverflowMakesTheRunNotResumable: more clock reads
// between two calls than the log keeps flag the run, and a stop while it
// waits ends it as before.
func TestAuto08_ClockReadOverflowMakesTheRunNotResumable(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox",
		`for (let i = 0; i < 10001; i++) { Date.now(); } `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	stop := runExecutor(t, w.exFixture)
	w.waitStatus(t, id, db.RunWaiting)
	if !w.run(t, id).NotResumable {
		t.Fatal("the run is not flagged not resumable after 10 001 clock reads")
	}
	stop()
	w.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
}

// TestAuto08_KeptRunChangedBeforeItsClaimIsNotResumed: a run the start kept
// whose automation is re-confirmed at another hash, or disabled, before the
// poll claims it is ended failed/interrupted, not resumed.
func TestAuto08_KeptRunChangedBeforeItsClaimIsNotResumed(t *testing.T) {
	changes := map[string]string{
		"reconfirmed": `UPDATE automations SET approval_hash = 'h-new', confirmed_hash = 'h-new' WHERE id = ?`,
		"disabled":    `UPDATE automations SET enabled = 0 WHERE id = ?`,
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			w := newWriteFixture(t)
			a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner"}, "inbox", `log("a"); `+resumeAskCall+`; return 1`)
			id := w.enqueue(t, a, db.TriggerManual)
			w.stopWhileWaiting(t, id)
			w.restart()
			if _, err := w.d.MarkInterruptedAutomationRuns(w.clock.Now()); err != nil { // the start sweep
				t.Fatal(err)
			}
			if !w.run(t, id).ResumePending {
				t.Fatal("the start sweep did not keep the run")
			}
			if _, err := w.d.Exec(change, a.ID); err != nil {
				t.Fatal(err)
			}
			w.stepNoWait(t, 0)
			r := w.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
			mustContain(t, "error", r.Error, "so the run was not resumed")
		})
	}
}

// seedReplyWait seeds a workbench recipe with ask:owner and inbox:reply whose
// script waits on an ask, queues a reply run of it and stops the executor
// while the run waits.
func (w *writeFixture) seedReplyWait(t *testing.T) (db.Automation, int64) {
	t.Helper()
	a := w.seedWorkbenchOutput(t, "triage", []string{"ask:owner", "inbox:reply"}, "inbox",
		`log("a"); `+resumeAskCall+`; return trigger.kind + ":" + trigger.reply.value + ":" + trigger.reply.data.id`)
	id := w.enqueueReply(t, a)
	w.stopWhileWaiting(t, id)
	return a, id
}

// TestAuto08_ResumedReplyRunKeepsTriggerReply: a resumed reply run sees the
// same trigger.reply, rebuilt from its stored payload.
func TestAuto08_ResumedReplyRunKeepsTriggerReply(t *testing.T) {
	w := newWriteFixture(t)
	a, id := w.seedReplyWait(t)
	ask := w.onlyAsk(t, a.ProjectID)
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, ask.ID)
	w.e.Wake()
	r := w.waitEnded(t, id)
	if r.Status != db.RunSucceeded || r.Summary != "reply:backlog:A-1" {
		t.Fatalf("run = %s/%s %q (%s); want succeeded reply:backlog:A-1", r.Status, r.ErrorKind, r.Summary, r.Error)
	}
}

// TestAuto08_ResumedReplyRunIsCheckedForInboxReply: the inbox:reply check
// runs on a resume too — a snapshot without the entry ends the resumed run
// failed/permission before any of its script replays.
func TestAuto08_ResumedReplyRunIsCheckedForInboxReply(t *testing.T) {
	w := newWriteFixture(t)
	_, id := w.seedReplyWait(t)
	res, err := w.d.Exec(`UPDATE automation_runs SET recipe_snapshot = replace(recipe_snapshot, '  - inbox:reply'||char(10), '')
		WHERE id = ?`, id)
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := res.RowsAffected(); n != 1 || strings.Contains(w.run(t, id).RecipeSnapshot, "inbox:reply") {
		t.Fatal("the snapshot still carries inbox:reply")
	}
	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	r := w.waitEnded(t, id)
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindPermission {
		t.Fatalf("run = %s/%s (%s); want failed/permission", r.Status, r.ErrorKind, r.Error)
	}
	mustContain(t, "error", r.Error, "inbox:reply")
	if got := stepSeqsAndKinds(w.steps(t, id)); got != "1:log:ok,2:ask:error" {
		t.Fatalf("steps = %s; want nothing replayed", got)
	}
}
