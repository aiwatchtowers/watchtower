package automations_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

func TestExecutor_RunsQueuedToSucceeded(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `state.set("seen", 1);
output.inbox({title: "Hi", body: "b"});
output.report({title: "Report title", body: "r"});
tool("list_targets", {});
return llm("summarise")`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")
	if r.Summary != "Report title" || r.InputTokens != 10 || r.OutputTokens != 5 || r.FinishedAt == nil {
		t.Fatalf("run = %+v; want summary \"Report title\", 10+5 tokens, finished", r)
	}
	if r.RecipeHash != a.ApprovalHash || r.RecipeSnapshot != a.RecipeText {
		t.Fatalf("run snapshot = %q/%q; want the indexed hash and text", r.RecipeHash, r.RecipeSnapshot)
	}
	state, err := f.d.GetAutomationState(a.ID)
	if err != nil || string(state) != `{"seen":1}` {
		t.Fatalf("state = %s, %v", state, err)
	}
	if n := f.count(t, "automation_outputs"); n != 2 {
		t.Fatalf("outputs = %d; want 2", n)
	}
	if got := stepStatusesOf(f.steps(t, id)); got != "state:ok,output:ok,output:ok,tool:ok,llm:ok" {
		t.Fatalf("steps = %s", got)
	}
}

// failCase is one way a run fails after buffering state and an output.
type failCase struct {
	name, tail string
	gen        digest.Generator
	act        func(t *testing.T, f *exFixture, id int64)
	status     string
}

func failCases() []failCase {
	blocking := newBlockingGen()
	return []failCase{
		{name: "throw", tail: `throw new Error("boom")`, status: db.RunFailed},
		{name: "timeout", tail: `jump(); while (true) {}`, status: db.RunTimedOut},
		{name: "budget", tail: `llm("x"); return 1`, gen: usageGen(40000, 20000), status: db.RunBudgetExceeded},
		{name: "cancel", tail: `llm("x"); return 1`, gen: blocking, status: db.RunCancelled,
			act: func(t *testing.T, f *exFixture, id int64) {
				blocking.waitEntered(t)
				if ok, err := f.d.CancelAutomationRun(id, f.clock.Now()); err != nil || !ok {
					t.Fatalf("cancel = (%v, %v)", ok, err)
				}
				f.e.Wake()
			}},
	}
}

func TestAuto04_FailedRunLeavesStateAndOutputsUnchanged(t *testing.T) {
	for _, tc := range failCases() {
		t.Run(tc.name, func(t *testing.T) {
			f := newExFixture(t, exOpts{gen: tc.gen, modules: jumpModules(0)})
			a := f.seed(t, "digest", `state.set("k", 2); output.inbox({title: "new", body: "x"}); `+tc.tail, false)
			f.commitPrior(t, a)
			before := f.dump(t)
			id := f.enqueue(t, a, db.TriggerManual)
			f.stepNoWait(t, 1)
			if tc.act != nil {
				tc.act(t, f, id)
			}
			f.e.Wait()
			if r := f.run(t, id); r.Status != tc.status {
				t.Fatalf("run = %s/%s (%s); want %s", r.Status, r.ErrorKind, r.Error, tc.status)
			}
			if after := f.dump(t); after != before {
				t.Fatalf("state/outputs changed:\nbefore %s\nafter  %s", before, after)
			}
		})
	}
}

// jumpModules adds jump() (pastDeadlineModule) over the fixture's clock.
func jumpModules(sleep time.Duration) func(f *exFixture) []automations.Module {
	return func(f *exFixture) []automations.Module {
		return []automations.Module{pastDeadlineModule(f.clock, sleep)}
	}
}

func TestAuto04_SucceededCommitsStateAndOutputsAtomically(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `state.set("k", 3); output.inbox({title: "one", body: "1"});
output.report({title: "two", body: "2"}); return "ok"`, false)
	f.commitPrior(t, a)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")
	var stateRun int64
	var updated string
	if err := f.d.QueryRow(`SELECT state_json = '{"k":3}', run_id, updated_at FROM automation_state WHERE automation_id = ?`,
		a.ID).Scan(new(bool), &stateRun, &updated); err != nil || stateRun != id {
		t.Fatalf("state row run_id = %d, %v; want %d", stateRun, err, id)
	}
	outs, err := f.d.ListAutomationOutputs("", 0)
	if err != nil || len(outs) != 3 {
		t.Fatalf("outputs = %d, %v; want the prior one plus 2", len(outs), err)
	}
	finished := r.FinishedAt.UTC().Format("2006-01-02T15:04:05Z")
	for _, o := range outs[:2] {
		if o.RunID != id || o.CreatedAt.UTC().Format("2006-01-02T15:04:05Z") != finished {
			t.Fatalf("output %+v; want run %d stamped with the finish %s", o, id, finished)
		}
	}
	if updated != finished {
		t.Fatalf("state updated_at %s; want the finish %s (one transaction)", updated, finished)
	}
}

func TestAuto08_InterruptOnBudget(t *testing.T) {
	gen := usageGen(20000, 10000)
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `llm("a"); llm("b"); llm("c"); return 1`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunBudgetExceeded, db.ErrKindBudget)
	if n := gen.CallCount(); n != 2 {
		t.Fatalf("generator calls = %d; want 2 (the third never reaches it)", n)
	}
}

// TestAuto08_CatchAllLoopStillEndsOnBudget pins Review Focus 2: a script that
// catches every error still ends on its budget.
func TestAuto08_CatchAllLoopStillEndsOnBudget(t *testing.T) {
	gen := usageGen(20000, 10000)
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `while (true) { try { llm("x") } catch (e) {} }`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunBudgetExceeded, db.ErrKindBudget)
	if n := gen.CallCount(); n != 2 {
		t.Fatalf("generator calls = %d; want 2", n)
	}
}

// TestAuto08_NoDailyCapAcrossRuns: there is no token cap across runs (D25,
// ask #294) — any amount spent today by other runs does not stop this one;
// only its own budget does.
func TestAuto08_NoDailyCapAcrossRuns(t *testing.T) {
	gen := usageGen(1500, 500)
	f := newExFixture(t, exOpts{gen: gen})
	f.priorTokens(t, f.seed(t, "other", `return 1`, false), exStart.Add(-time.Hour), 50000000)
	id := f.enqueue(t, f.seed(t, "digest", `llm("a"); llm("b"); return 1`, false), db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if n := gen.CallCount(); n != 2 {
		t.Fatalf("generator calls = %d; want 2", n)
	}
}

func TestBudget_EstimatesTokensWhenUsageMissing(t *testing.T) {
	gen := &noUsageGen{reply: "wxyz"}
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `return llm("abcdefgh")`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunSucceeded, "")
	want := int64(len(gen.system)+len(gen.user)+len("wxyz")+3) / 4
	if !r.TokensEstimated || r.InputTokens+r.OutputTokens != want || r.ReportedCostUSD != nil {
		t.Fatalf("run tokens %d+%d estimated=%v cost=%v; want %d estimated, no cost",
			r.InputTokens, r.OutputTokens, r.TokensEstimated, r.ReportedCostUSD, want)
	}
}

// noUsageGen replies without usage and remembers
// the prompt it got.
type noUsageGen struct {
	reply, system, user string
}

func (g *noUsageGen) Generate(_ context.Context, system, user, sid string) (string, *digest.Usage, string, error) {
	g.system, g.user = system, user
	return g.reply, nil, sid, nil
}

func TestAuto05_OneActiveRunPerAutomation(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `llm("x"); return 1`, false)
	first := f.enqueue(t, a, db.TriggerManual)
	second := f.enqueue(t, a, db.TriggerCatchUp)
	f.stepNoWait(t, 1)
	gen.waitEntered(t)
	f.wantRun(t, second, db.RunQueued, "")
	close(gen.release)
	f.e.Wait()
	f.wantRun(t, first, db.RunSucceeded, "")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
}

func TestExecutor_MaxConcurrentRuns(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen, maxConcurrent: 2})
	var ids []int64
	for _, slug := range []string{"one", "two", "three"} {
		ids = append(ids, f.enqueue(t, f.seed(t, slug, `llm("x"); return 1`, false), db.TriggerManual))
	}
	f.stepNoWait(t, 2)
	gen.waitEntered(t)
	gen.waitEntered(t)
	f.stepNoWait(t, 0)
	f.wantRun(t, ids[2], db.RunQueued, "")
	close(gen.release)
	f.e.Wait()
	f.step(t, 1)
	for _, id := range ids {
		f.wantRun(t, id, db.RunSucceeded, "")
	}
}

func TestAuto06_UnconfirmedRecipeIsCancelledNotRun(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return llm("x")`, true)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 0)
	f.wantRun(t, id, db.RunCancelled, db.ErrKindNotRunnable)
	if n := fakeGenCalls(t, f.gen); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}

func TestAuto06_DryRunOfUnconfirmedRecipeRuns(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `output.inbox({title: "t", body: "b"}); return llm("x")`, true)
	id := f.enqueue(t, a, db.TriggerDryRun)
	f.step(t, 0) // the daemon's poll never picks up a dry run
	f.wantRun(t, id, db.RunQueued, "")
	r, err := f.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v; want succeeded", r, err)
	}
	if got := stepStatusesOf(f.steps(t, id)); got != "output:dry_run,llm:ok" {
		t.Fatalf("steps = %s", got)
	}
	if n := f.count(t, "automation_outputs"); n != 0 {
		t.Fatalf("outputs = %d; want 0", n)
	}

	broken := f.seedText(t, "broken", "---\nname: Broken\n---\nno script\n", true)
	if broken.ParseError == "" {
		t.Fatal("the broken recipe parsed")
	}
	bid := f.enqueue(t, broken, db.TriggerDryRun)
	if r, err := f.e.ExecuteInline(context.Background(), bid); err != nil || r.Status != db.RunFailed ||
		r.ErrorKind != db.ErrKindNotRunnable {
		t.Fatalf("ExecuteInline(broken) = %+v, %v; want failed/not_runnable", r, err)
	}
}

func TestAuto06_ExecutorRunsIndexedCopyNotFile(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return "indexed"`, false)
	f.write(t, "digest", exRecipeText(`return "file"`, ""))
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "indexed" {
		t.Fatalf("summary = %q; want the indexed script's result", r.Summary)
	}
}

// TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot pins Review Focus 1.
func TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `llm("x"); return "old"`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.stepNoWait(t, 1)
	gen.waitEntered(t)
	f.write(t, "digest", exRecipeText(`llm("x"); return "new"`, ""))
	edited := f.rescan(t, "digest")
	if edited.Runnable() || edited.ApprovalHash == a.ApprovalHash {
		t.Fatalf("edited row runnable=%v hash changed=%v; want not runnable with a new hash",
			edited.Runnable(), edited.ApprovalHash != a.ApprovalHash)
	}
	close(gen.release)
	f.e.Wait()
	r := f.wantRun(t, id, db.RunSucceeded, "")
	if r.Summary != "old" || r.RecipeHash != a.ApprovalHash {
		t.Fatalf("run summary %q hash %q; want the claimed snapshot's \"old\" and %q", r.Summary, r.RecipeHash, a.ApprovalHash)
	}
	next := f.enqueue(t, edited, db.TriggerManual)
	f.step(t, 0)
	f.wantRun(t, next, db.RunCancelled, db.ErrKindNotRunnable)
}

// claimAt claims run id of a at started with a 5-minute budget, as another
// process would.
func (f *exFixture) claimAt(t *testing.T, a db.Automation, id int64, started time.Time) {
	t.Helper()
	if ok, err := f.d.ClaimAutomationRun(id, a.ApprovalHash, a.RecipeText, 50000, 5, started); err != nil || !ok {
		t.Fatalf("claim %d = (%v, %v)", id, ok, err)
	}
}

func cancelledCtx() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

func TestAuto08_RestartMarksInterrupted(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return 1`, false)
	stale := f.enqueue(t, a, db.TriggerManual)
	f.claimAt(t, a, stale, exStart.Add(-time.Minute))
	queued := f.enqueue(t, f.seed(t, "other", `return 1`, false), db.TriggerManual)
	if err := f.e.Run(cancelledCtx()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	f.wantRun(t, stale, db.RunFailed, db.ErrKindInterrupted)
	f.wantRun(t, queued, db.RunQueued, "") // nothing was claimed: the stop came right after the start
}

func TestExecutor_StartSparesLiveCLIDryRun(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return 1`, true)
	dry := f.enqueue(t, a, db.TriggerDryRun)
	f.claimAt(t, a, dry, exStart.Add(-time.Minute))
	if err := f.e.Run(cancelledCtx()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	f.wantRun(t, dry, db.RunRunning, "")
}

func TestExecutor_SweepsStaleDryRuns(t *testing.T) {
	f := newExFixture(t, exOpts{maxConcurrent: 1})
	a := f.seed(t, "digest", `return 1`, false)
	dry := f.enqueue(t, a, db.TriggerDryRun)
	f.claimAt(t, a, dry, exStart.Add(-10*time.Minute)) // its CLI died: 5 min budget + 1 min grace are long past
	other := f.enqueue(t, f.seed(t, "other", `return 1`, false), db.TriggerManual)
	f.step(t, 1) // the swept dry run no longer holds the only slot
	f.wantRun(t, dry, db.RunFailed, db.ErrKindInterrupted)
	f.wantRun(t, other, db.RunSucceeded, "")
}

func TestAuto12_DryRunWritesNoActionsOutputsOrState(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `state.set("k", 9); output.inbox({title: "t", body: "b"});
tool("list_targets", {}); return llm("x")`, false)
	f.commitPrior(t, a)
	before, actions := f.dump(t), f.count(t, "agent_actions")
	id := f.enqueue(t, a, db.TriggerDryRun)
	r, err := f.e.ExecuteInline(context.Background(), id)
	if err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("ExecuteInline = %+v, %v", r, err)
	}
	if after := f.dump(t); after != before {
		t.Fatalf("state/outputs changed:\nbefore %s\nafter  %s", before, after)
	}
	if n := f.count(t, "agent_actions"); n != actions {
		t.Fatalf("agent_actions = %d; want %d", n, actions)
	}
	if got := stepStatusesOf(f.steps(t, id)); got != "state:dry_run,output:dry_run,tool:ok,llm:ok" {
		t.Fatalf("steps = %s", got)
	}
	if r.InputTokens != 10 || r.OutputTokens != 5 {
		t.Fatalf("dry run tokens = %d+%d; want 10+5 counted on the run", r.InputTokens, r.OutputTokens)
	}
}

func TestExecutor_CancelQueued(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return llm("x")`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	if ok, err := f.d.CancelAutomationRun(id, exStart); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	f.step(t, 0)
	if r := f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled); r.StartedAt != nil {
		t.Fatalf("the cancelled run started at %v", r.StartedAt)
	}
	if n := fakeGenCalls(t, f.gen); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}

func TestExecutor_UncaughtPermissionDeniedFailsWithPermissionKind(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return llm("x", {tier: "strong"})`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindPermission)
	mustContain(t, "error", r.Error, "PermissionDenied")
}

// waitModule defines waitFor(): a wait on the executor's Waiter until ready
// reports true.
func waitModule(ready *atomic.Bool) automations.Module {
	return exModule{name: "wait", fns: map[string]automations.SDKFunc{
		"waitFor": func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			err := env.Wait.Wait(env.Ctx, db.WaitApproval, func(context.Context) (bool, error) { return ready.Load(), nil })
			return "resumed", err
		},
	}}
}

func TestWaiter_PauseTimeoutExpires(t *testing.T) {
	t.Run("expires", func(t *testing.T) {
		var ready atomic.Bool
		f := newExFixture(t, exOpts{modules: func(*exFixture) []automations.Module { return []automations.Module{waitModule(&ready)} }})
		id := f.enqueue(t, f.seed(t, "digest", `waitFor(); return 1`, false), db.TriggerManual)
		f.stepNoWait(t, 1)
		f.waitStatus(t, id, db.RunWaiting)
		f.clock.Advance(73 * time.Hour) // past the default pause_timeout_hours of 72
		f.e.Wake()
		f.e.Wait()
		f.wantRun(t, id, db.RunExpired, db.ErrKindExpired)
	})
	t.Run("resumes", func(t *testing.T) {
		var ready atomic.Bool
		f := newExFixture(t, exOpts{modules: func(*exFixture) []automations.Module { return []automations.Module{waitModule(&ready)} }})
		id := f.enqueue(t, f.seed(t, "digest", `return waitFor()`, false), db.TriggerManual)
		f.stepNoWait(t, 1)
		f.waitStatus(t, id, db.RunWaiting)
		f.clock.Advance(time.Hour)
		ready.Store(true)
		f.e.Wake()
		f.e.Wait()
		r := f.wantRun(t, id, db.RunSucceeded, "")
		if r.Summary != "resumed" || r.ActiveMS >= time.Hour.Milliseconds() || r.WaitingReason != "" {
			t.Fatalf("run summary %q active_ms %d reason %q; want resumed with the hour of pause excluded",
				r.Summary, r.ActiveMS, r.WaitingReason)
		}
	})
}

func eventPayload(t *testing.T, events ...map[string]any) string {
	t.Helper()
	p := db.AutomationEventPayload{Cycles: []string{"c1"}, Count: len(events)}
	for _, ev := range events {
		raw, err := json.Marshal(ev)
		if err != nil {
			t.Fatal(err)
		}
		p.Events = append(p.Events, raw)
	}
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func TestExecutor_EventRunExposesTriggerEvents(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return trigger.events.length + ":" + trigger.events[0].channel + ":" + trigger.truncated`, false)
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: "c1",
		EventJSON: eventPayload(t, map[string]any{"channel": "releases"}, map[string]any{"channel": "general"})})
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "2:releases:false" {
		t.Fatalf("summary = %q; want 2:releases:false", r.Summary)
	}
}

func TestExecutor_NonEventRunHasNoEvents(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return (typeof trigger.events) + ":" + (trigger.truncated === false) + ":" + trigger.kind`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "undefined:true:manual" {
		t.Fatalf("summary = %q; want undefined:true:manual", r.Summary)
	}
}

func TestExecutor_MalformedEventJSONFailsAsBackend(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return llm("x")`, false)
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: "c1", EventJSON: "{"})
	f.step(t, 1)
	f.wantRun(t, id, db.RunFailed, db.ErrKindBackend)
	if n := fakeGenCalls(t, f.gen); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}

func waitNoAbandoned(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for automations.AbandonedRuns() > 0 {
		if time.Now().After(deadline) {
			t.Fatalf("AbandonedRuns = %d after 30 s", automations.AbandonedRuns())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestExecutor_AbandonedRunDisablesAutomation(t *testing.T) {
	waitNoAbandoned(t)
	t.Cleanup(func() { waitNoAbandoned(t) })
	f := newExFixture(t, exOpts{modules: jumpModules(automations.AbandonGrace + 2*time.Second)})
	a := f.seed(t, "digest", `jump(); return 1`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunTimedOut, db.ErrKindTimeout)
	mustContain(t, "run error", r.Error, "runaway script — check and re-enable")
	mustContain(t, "log", f.logs.String(), "abandoned")
	got, err := f.d.GetAutomation(a.ID)
	if err != nil || got.Enabled {
		t.Fatalf("automation enabled=%v, %v; want disabled", got.Enabled, err)
	}
}

// A script that hits a sandbox size or depth limit — here the nesting that
// used to overflow the Go stack and kill the daemon — fails with a clear,
// uncatchable RangeError and its automation is disabled, so the next tick
// does not run it again.
func TestExecutor_LimitHitDisablesAutomation(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `try { JSON.parse("[".repeat(16e6)) } catch (e) { return "caught" }`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindScript)
	mustContain(t, "run error", r.Error, "RangeError: JSON.parse: the text is nested deeper than 1000 levels")
	mustContain(t, "run error", r.Error, "the automation was disabled: runaway script — check and re-enable")
	mustContain(t, "log", f.logs.String(), "automation disabled")
	got, err := f.d.GetAutomation(a.ID)
	if err != nil || got.Enabled {
		t.Fatalf("automation enabled=%v, %v; want disabled", got.Enabled, err)
	}
	// The script's own RangeError is an ordinary failure.
	own := f.seed(t, "own", `throw new RangeError("mine")`, false)
	ownRun := f.enqueue(t, own, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, ownRun, db.RunFailed, db.ErrKindScript)
	if got, err := f.d.GetAutomation(own.ID); err != nil || !got.Enabled {
		t.Fatalf("own RangeError: automation enabled=%v, %v; want enabled", got.Enabled, err)
	}
}

func TestExecutor_NoClaimsWhileTwoRunsAbandoned(t *testing.T) {
	f := newExFixture(t, exOpts{})
	id := f.enqueue(t, f.seed(t, "digest", `return 1`, false), db.TriggerManual)
	unconfirmed := f.enqueue(t, f.seed(t, "draft", `return 1`, true), db.TriggerManual)
	abandoned := 2
	automations.SetExecutorAbandoned(f.e, func() int { return abandoned })
	f.step(t, 0)
	f.step(t, 0)
	f.wantRun(t, id, db.RunQueued, "")
	f.wantRun(t, unconfirmed, db.RunCancelled, db.ErrKindNotRunnable) // still cancelled while gated
	if n := strings.Count(f.logs.String(), "no run is claimed"); n != 1 {
		t.Fatalf("gate logged %d times over two polls; want once:\n%s", n, f.logs.String())
	}
	abandoned = 1
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	mustContain(t, "log", f.logs.String(), "claiming again")
}

func TestExecutor_ExecuteInlineRefusesLostClaim(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "digest", `return 1`, false)
	id := f.enqueue(t, a, db.TriggerDryRun)
	f.claimAt(t, a, id, exStart)
	if _, err := f.e.ExecuteInline(context.Background(), id); !errors.Is(err, automations.ErrRunNotClaimed) {
		t.Fatalf("ExecuteInline of a claimed run = %v; want ErrRunNotClaimed", err)
	}
}

// TestWaiter_ResumeWaitsForAFreeSlot: waiting runs hold no slot, so a wait
// that becomes ready while MaxConcurrent runs are running stays waiting until
// one of them finishes.
func TestWaiter_ResumeWaitsForAFreeSlot(t *testing.T) {
	var ready atomic.Bool
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen, maxConcurrent: 2, modules: func(*exFixture) []automations.Module {
		return []automations.Module{waitModule(&ready)}
	}})
	var waiters, busy []int64
	for _, slug := range []string{"wait-one", "wait-two"} {
		waiters = append(waiters, f.enqueue(t, f.seed(t, slug, `return waitFor()`, false), db.TriggerManual))
	}
	f.stepNoWait(t, 2)
	for _, id := range waiters {
		f.waitStatus(t, id, db.RunWaiting)
	}
	for _, slug := range []string{"busy-one", "busy-two"} {
		busy = append(busy, f.enqueue(t, f.seed(t, slug, `llm("x"); return 1`, false), db.TriggerManual))
	}
	f.stepNoWait(t, 2) // the waiting runs hold no slot
	gen.waitEntered(t)
	gen.waitEntered(t)
	ready.Store(true)
	f.e.Wake()
	time.Sleep(200 * time.Millisecond) // give the waits a chance to (wrongly) resume
	for _, id := range waiters {
		f.wantRun(t, id, db.RunWaiting, "")
	}
	close(gen.release) // the busy runs finish and wake the waits
	f.e.Wait()
	for _, id := range append(waiters, busy...) {
		f.wantRun(t, id, db.RunSucceeded, "")
	}
}

func TestExecutor_CancelledRunRecordsActiveTime(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	id := f.enqueue(t, f.seed(t, "digest", `llm("x"); return 1`, false), db.TriggerManual)
	f.stepNoWait(t, 1)
	gen.waitEntered(t)
	f.clock.Advance(30 * time.Second)
	if ok, err := f.d.CancelAutomationRun(id, f.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	f.e.Wake()
	f.e.Wait()
	if r := f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled); r.ActiveMS != 30000 {
		t.Fatalf("active_ms = %d; want 30000", r.ActiveMS)
	}
}

// runExecutor starts e.Run and returns a stop that cancels it and waits for
// it to return.
func runExecutor(t *testing.T, f *exFixture) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.e.Run(ctx) }()
	return func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
		case <-time.After(30 * time.Second):
			t.Fatal("Run did not return after its ctx ended")
		}
	}
}

func TestExecutor_DaemonStopMidRunEndsInterrupted(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	id := f.enqueue(t, f.seed(t, "digest", `llm("x"); return 1`, false), db.TriggerManual)
	stop := runExecutor(t, f)
	gen.waitEntered(t)
	stop()
	r := f.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
	mustContain(t, "error", r.Error, "the daemon stopped")
}

func TestWaiter_CancelOfWaitingRunEndsCancelled(t *testing.T) {
	var ready atomic.Bool
	f := newExFixture(t, exOpts{modules: func(*exFixture) []automations.Module { return []automations.Module{waitModule(&ready)} }})
	id := f.enqueue(t, f.seed(t, "digest", `waitFor(); return 1`, false), db.TriggerManual)
	f.stepNoWait(t, 1)
	f.waitStatus(t, id, db.RunWaiting)
	if ok, err := f.d.CancelAutomationRun(id, f.clock.Now()); err != nil || !ok {
		t.Fatalf("cancel = (%v, %v)", ok, err)
	}
	f.e.Wake()
	f.e.Wait()
	f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
}

func TestWaiter_DaemonStopDuringWaitEndsInterrupted(t *testing.T) {
	var ready atomic.Bool
	f := newExFixture(t, exOpts{modules: func(*exFixture) []automations.Module { return []automations.Module{waitModule(&ready)} }})
	id := f.enqueue(t, f.seed(t, "digest", `waitFor(); return 1`, false), db.TriggerManual)
	stop := runExecutor(t, f)
	f.waitStatus(t, id, db.RunWaiting)
	stop()
	f.wantRun(t, id, db.RunFailed, db.ErrKindInterrupted)
}

func TestExecutor_ExecuteInlineStopSaysDryRunStopped(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	id := f.enqueue(t, f.seed(t, "digest", `llm("x"); return 1`, true), db.TriggerDryRun)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-gen.entered
		cancel()
	}()
	r, err := f.e.ExecuteInline(ctx, id)
	if err != nil {
		t.Fatalf("ExecuteInline: %v", err)
	}
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindInterrupted || !strings.Contains(r.Error, "the dry run was stopped") {
		t.Fatalf("run = %s/%s (%s); want failed/interrupted saying the dry run was stopped", r.Status, r.ErrorKind, r.Error)
	}
}

// holdModule defines hold(): a native call that blocks until gate closes.
func holdModule(gate <-chan struct{}) automations.Module {
	return exModule{name: "hold", fns: map[string]automations.SDKFunc{
		"hold": func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			select {
			case <-gate:
			case <-env.Ctx.Done():
			}
			return nil, nil
		},
	}}
}

// slotFixture: MaxConcurrent 2, waitFor() and hold() installed, two ready
// waits owed a slot while two dry runs claimed by another process hold both
// running slots.
type slotFixture struct {
	*exFixture
	ready            *atomic.Bool
	gate             chan struct{}
	waiters, holders []int64
}

func newSlotFixture(t *testing.T) *slotFixture {
	t.Helper()
	sf := &slotFixture{ready: &atomic.Bool{}, gate: make(chan struct{})}
	sf.exFixture = newExFixture(t, exOpts{maxConcurrent: 2, modules: func(*exFixture) []automations.Module {
		return []automations.Module{waitModule(sf.ready), holdModule(sf.gate)}
	}})
	for _, slug := range []string{"wait-one", "wait-two"} {
		sf.waiters = append(sf.waiters, sf.enqueue(t, sf.seed(t, slug, `waitFor(); hold(); return 1`, false), db.TriggerManual))
	}
	sf.stepNoWait(t, 2)
	for _, id := range sf.waiters {
		sf.waitStatus(t, id, db.RunWaiting)
	}
	for _, slug := range []string{"held-one", "held-two"} {
		a := sf.seed(t, slug, `return 1`, false)
		id := sf.enqueue(t, a, db.TriggerDryRun)
		sf.claimAt(t, a, id, sf.clock.Now())
		sf.holders = append(sf.holders, id)
	}
	sf.ready.Store(true)
	sf.e.Wake()
	deadline := time.Now().Add(10 * time.Second)
	for automations.ExecutorReadyWaits(sf.e) != 2 {
		if time.Now().After(deadline) {
			t.Fatalf("ready waits = %d; want 2 waiting for a slot", automations.ExecutorReadyWaits(sf.e))
		}
		time.Sleep(5 * time.Millisecond)
	}
	return sf
}

// freeHolders ends the holders' runs directly in the store: no Wake, so the
// waits are not told.
func (sf *slotFixture) freeHolders(t *testing.T) {
	t.Helper()
	for _, id := range sf.holders {
		if err := sf.d.FinishAutomationRun(id, db.RunFinish{Status: db.RunSucceeded, Now: sf.clock.Now()}, nil); err != nil {
			t.Fatal(err)
		}
	}
}

// TestExecutor_ReadyWaitsGetFreedSlotsBeforeQueuedRuns: slots freed while
// ready waits are owed them are not given to a queued run.
func TestExecutor_ReadyWaitsGetFreedSlotsBeforeQueuedRuns(t *testing.T) {
	sf := newSlotFixture(t)
	queued := sf.enqueue(t, sf.seed(t, "queued", `return 1`, false), db.TriggerManual)
	sf.freeHolders(t)
	sf.stepNoWait(t, 0) // the freed slots belong to the ready waits
	sf.wantRun(t, queued, db.RunQueued, "")
	sf.e.Wake()
	for _, id := range sf.waiters {
		sf.waitStatus(t, id, db.RunRunning)
	}
	close(sf.gate)
	sf.e.Wait()
	sf.step(t, 1)
	for _, id := range append(sf.waiters, queued) {
		sf.wantRun(t, id, db.RunSucceeded, "")
	}
}

// TestWaiter_SlotWaitStillExpires: a ready wait that never gets a slot still
// ends expired after pause_timeout_hours.
func TestWaiter_SlotWaitStillExpires(t *testing.T) {
	sf := newSlotFixture(t)
	sf.clock.Advance(73 * time.Hour)
	sf.e.Wake()
	sf.e.Wait()
	for _, id := range sf.waiters {
		sf.wantRun(t, id, db.RunExpired, db.ErrKindExpired)
	}
	close(sf.gate)
}

// A caller that checked the recipe at one approval hash (the CLI's D16 gate)
// never runs a recipe a rescan changed in between: the run is cancelled.
func TestExecutor_ExecuteInlinePinnedRefusesChangedRecipe(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"done"}}
	f := newExFixture(t, exOpts{gen: gen})
	a := f.seed(t, "digest", `return llm("x")`, false)
	id := f.enqueue(t, a, db.TriggerDryRun)
	f.write(t, "digest", exRecipeText(`llm("x"); return llm("y")`, ""))
	if changed := f.rescan(t, "digest"); changed.ApprovalHash == a.ApprovalHash {
		t.Fatal("the rescan did not change the approval hash")
	}
	r, err := f.e.ExecuteInlinePinned(context.Background(), id, a.ApprovalHash)
	if !errors.Is(err, automations.ErrRecipeChanged) || r != nil {
		t.Fatalf("ExecuteInlinePinned = %+v, %v; want ErrRecipeChanged", r, err)
	}
	f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
	if n := gen.CallCount(); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}
