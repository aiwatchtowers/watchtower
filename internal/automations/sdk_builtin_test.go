package automations_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// builtinRecipe is a built-in's recipe at slot morning_brief; PERMS, EXTRA
// (more frontmatter lines) and SCRIPT are replaced.
const builtinRecipe = "---\nname: Morning brief\ntrigger:\n  sync: morning_brief\npermissions:\nPERMSoutputs: [inbox]\n" +
	"EXTRA---\nThe built-in test recipe.\n\n```js\nSCRIPT\n```\n"

func builtinRecipeText(script, extra string, perms ...string) string {
	var p strings.Builder
	for _, e := range perms {
		p.WriteString("  - " + e + "\n")
	}
	return strings.NewReplacer("PERMS", p.String(), "EXTRA", extra, "SCRIPT", script).Replace(builtinRecipe)
}

const testBuiltinID = "morning-brief"

// seedBuiltin indexes text as the built-in row testBuiltinID (as the
// built-in indexer would) and, when confirmed, confirms the shipped bytes.
func (f *exFixture) seedBuiltin(t *testing.T, text string, confirmed bool) db.Automation {
	t.Helper()
	scope := automations.Scope{Kind: automations.ScopePersonal, BuiltinID: testBuiltinID}
	r, err := automations.ParseRecipe(testBuiltinID, []byte(text), scope)
	if err != nil {
		t.Fatalf("parse built-in: %v", err)
	}
	a := db.Automation{
		BuiltinID: testBuiltinID, Slug: testBuiltinID, Name: r.Name,
		TriggerKind: db.TriggerKindSync, TriggerSpec: `{"sync":"morning_brief"}`,
		Concurrency: r.Concurrency, BudgetTokens: r.Budget.Tokens, BudgetMinutes: r.Budget.Minutes,
		PauseTimeoutHours: r.PauseTimeoutHours, PermissionsJSON: `[]`, OutputsJSON: `["inbox"]`,
		RecipeText: text, ContentHash: automations.ContentHash([]byte(text)), ApprovalHash: automations.ApprovalHash(r),
	}
	id, err := f.d.UpsertBuiltinAutomation(a)
	if err != nil {
		t.Fatal(err)
	}
	if confirmed {
		if err := f.d.ConfirmShippedBuiltin(id, a.ContentHash, a.ApprovalHash, exStart); err != nil {
			t.Fatal(err)
		}
	}
	row, err := f.d.GetAutomation(id)
	if err != nil {
		t.Fatal(err)
	}
	return *row
}

// fakePrimitive records its calls and answers with res/err.
type fakePrimitive struct {
	mu    sync.Mutex
	calls []automations.PrimitiveCall
	res   automations.PrimitiveResult
	err   error
}

func (p *fakePrimitive) fn(_ context.Context, c automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls = append(p.calls, c)
	return p.res, p.err
}

func (p *fakePrimitive) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.calls)
}

func builtinFixture(t *testing.T, prims map[string]*fakePrimitive) *exFixture {
	t.Helper()
	return newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
		b.Primitives = map[string]automations.PrimitiveFunc{}
		for name, p := range prims {
			b.Primitives[name] = p.fn
		}
		b.DefaultPrompt = func(builtinID, name, role string) (string, error) {
			if name != "brief" {
				return "", errors.New("no such prompt")
			}
			return "default " + builtinID + "/" + name + "/" + role, nil
		}
	}})
}

// runBuiltin enqueues a run of a and executes it inline.
func (f *exFixture) runBuiltin(t *testing.T, a db.Automation, trigger, eventJSON string) *db.AutomationRun {
	t.Helper()
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: trigger, EventJSON: eventJSON})
	run, err := f.e.ExecuteBuiltinInline(context.Background(), id)
	if err != nil {
		t.Fatalf("ExecuteBuiltinInline: %v", err)
	}
	return run
}

func TestBuiltinSDK_AbsentOutsideBuiltinScope(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "plain", `return [typeof brief, typeof plan, typeof builtin].join(",");`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "undefined,undefined,undefined" {
		t.Errorf("summary = %q", r.Summary)
	}
}

func TestBuiltinSDK_NamespacePerDeclaredCapability(t *testing.T) {
	f := builtinFixture(t, nil)
	a := f.seedBuiltin(t, builtinRecipeText(
		`return [typeof brief, typeof plan, typeof builtin, typeof builtin.defaultPrompt, typeof builtin.input].join(",");`,
		"", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != "object,undefined,object,function,object" {
		t.Errorf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
}

func TestBuiltinSDK_ComposeCallsPrimitiveWithPrompt(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done", Fields: map[string]any{"briefing_id": 7},
		Note: "the placeholder fallback", Usage: automations.PrimitiveUsage{InputTokens: 100, OutputTokens: 20, CostUSD: 0.01, Reported: true}}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(
		`const r = brief.compose({prompt: "P"}); return r.status + ":" + r.briefing_id + ":" + builtin.input.date + ":" + builtin.defaultPrompt("brief");`,
		"", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, `{"builtin":{"date":"2026-10-20"}}`)
	if r.Status != db.RunSucceeded || r.Summary != "done:7:2026-10-20:default morning-brief/brief/" {
		t.Fatalf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	if p.count() != 1 {
		t.Fatalf("primitive called %d times", p.count())
	}
	c := p.calls[0]
	if c.Name != "brief.compose" || c.BuiltinID != testBuiltinID || c.Prompt != "P" || c.Trigger.Kind != db.TriggerSync ||
		c.Input.Date != "2026-10-20" || len(c.Args) != 0 {
		t.Errorf("call = %+v", c)
	}
	steps := f.steps(t, r.ID)
	if len(steps) != 1 {
		t.Fatalf("steps = %+v", steps)
	}
	s := steps[0]
	if s.Kind != automations.StepKindLLM || s.Name != "brief.compose" || s.Permission != "builtin:brief.compose" ||
		s.Status != automations.StepOK || s.InputTokens != 100 || s.OutputTokens != 20 ||
		!strings.Contains(s.ResultSummary, `"note":"the placeholder fallback"`) || !strings.Contains(s.ResultSummary, `"briefing_id":7`) {
		t.Errorf("step = %+v", s)
	}
	if r.InputTokens != 100 || r.OutputTokens != 20 || r.ReportedCostUSD == nil || *r.ReportedCostUSD != 0.01 {
		t.Errorf("run usage = %d/%d %v", r.InputTokens, r.OutputTokens, r.ReportedCostUSD)
	}
}

func TestBuiltinSDK_BadArgumentsAreValidationErrors(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`const out = [];
for (const arg of [{prompt: "P", date: "2026-01-01"}, {prompt: ""}, {prompt: 3}, {}, "P"]) {
  try { brief.compose(arg); out.push("ok"); } catch (e) { out.push(e.name); }
}
return out.join(",");`, "", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	want := strings.Repeat(automations.ErrNameValidation+",", 5)
	if r.Status != db.RunSucceeded || r.Summary != strings.TrimSuffix(want, ",") {
		t.Errorf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	if p.count() != 0 {
		t.Errorf("primitive called %d times", p.count())
	}
}

func TestBuiltinSDK_UsageCountsAgainstBudget(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done",
		Usage: automations.PrimitiveUsage{InputTokens: 4000, OutputTokens: 2000}}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"}); brief.compose({prompt: "P"}); return "end";`,
		"budget: {tokens: 5000}\n", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunBudgetExceeded || p.count() != 1 {
		t.Errorf("run = %s/%s (%s), primitive calls %d; want budget_exceeded after one call", r.Status, r.ErrorKind, r.Error, p.count())
	}
}

func TestBuiltinSDK_PrimitiveErrorFailsRunAsBackend(t *testing.T) {
	p := &fakePrimitive{err: errors.New("the model is down")}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"}); return "end";`, "", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindBackend || !strings.Contains(r.Error, automations.ErrNamePrimitiveFailed) ||
		!strings.Contains(r.Error, "the model is down") {
		t.Errorf("run = %s/%s (%s)", r.Status, r.ErrorKind, r.Error)
	}
	// Caught, it is the script's to handle.
	a = f.seedBuiltin(t, builtinRecipeText(`try { brief.compose({prompt: "P"}); } catch (e) { return e.name; }`, "", "builtin:brief.compose"), true)
	r = f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != automations.ErrNamePrimitiveFailed {
		t.Errorf("caught: run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
}

func TestAuto12_BuiltinPrimitiveDryRunCallsNothing(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`return brief.compose({prompt: "P"}).status;`, "", "builtin:brief.compose"), true)
	for _, c := range []struct{ eventJSON, date string }{
		{`{"builtin":{"date":"2026-10-20"}}`, "2026-10-20"},
		{"", exStart.In(time.Local).Format(time.DateOnly)},
	} {
		id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerDryRun, EventJSON: c.eventJSON})
		r, err := f.e.ExecuteInline(context.Background(), id)
		if err != nil {
			t.Fatal(err)
		}
		if r.Status != db.RunSucceeded || r.Summary != automations.StepDryRun {
			t.Errorf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
		}
		steps := f.steps(t, id)
		if len(steps) != 1 || steps[0].Status != automations.StepDryRun || steps[0].Permission != "builtin:brief.compose" ||
			steps[0].ResultSummary != `{"date":"`+c.date+`","would":"brief.compose"}` {
			t.Errorf("steps = %+v", steps)
		}
	}
	if p.count() != 0 {
		t.Errorf("a dry run called the primitive %d times", p.count())
	}
}

func TestExecutor_PollNeverClaimsBuiltinRuns(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"});`, "", "builtin:brief.compose"), true)
	if err := f.d.SetBuiltinEnabled(testBuiltinID, true, exStart); err != nil {
		t.Fatal(err)
	}
	unconfirmed := f.seedBuiltin(t, builtinRecipeText(`log(1);`, "", "builtin:brief.compose"), false)
	if unconfirmed.ID != a.ID || unconfirmed.Runnable() {
		t.Fatalf("the re-indexed built-in = %+v", unconfirmed)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 0) // not runnable now, yet the poll does not cancel it either
	if r := f.run(t, id); r.Status != db.RunQueued {
		t.Errorf("run = %s/%s; want queued", r.Status, r.ErrorKind)
	}
	f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"});`, "", "builtin:brief.compose"), true)
	f.step(t, 0) // runnable: still never claimed by the poll
	if r := f.run(t, id); r.Status != db.RunQueued || p.count() != 0 {
		t.Errorf("run = %s, primitive calls %d; want queued and none", r.Status, p.count())
	}
}

func TestAuto06_BuiltinInlineRefusesUnconfirmed(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"});`, "", "builtin:brief.compose"), false)
	id := f.enqueue(t, a, db.TriggerSync)
	if _, err := f.e.ExecuteBuiltinInline(context.Background(), id); !errors.Is(err, automations.ErrNotRunnable) {
		t.Fatalf("err = %v; want ErrNotRunnable", err)
	}
	f.wantRun(t, id, db.RunCancelled, db.ErrKindNotRunnable)
	if p.count() != 0 {
		t.Errorf("primitive called %d times", p.count())
	}
	// An owner automation is not a slot automation: refused the same way.
	owner := f.seed(t, "plain", `return 1;`, false)
	id = f.enqueue(t, owner, db.TriggerManual)
	if _, err := f.e.ExecuteBuiltinInline(context.Background(), id); !errors.Is(err, automations.ErrNotRunnable) {
		t.Fatalf("owner: err = %v; want ErrNotRunnable", err)
	}
}

func TestExecutor_BuiltinInlineRunsWhenDisabled(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "skipped"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`return brief.compose({prompt: "P"}).status;`, "", "builtin:brief.compose"), true)
	if a.Enabled {
		t.Fatal("the built-in row starts enabled")
	}
	r := f.runBuiltin(t, a, db.TriggerManual, `{"builtin":{"only":["brief.compose"],"force":true}}`)
	if r.Status != db.RunSucceeded || r.Summary != "skipped" || p.count() != 1 {
		t.Fatalf("run = %s %q (%s), calls %d", r.Status, r.Summary, r.Error, p.count())
	}
	if c := p.calls[0]; c.Trigger.Kind != db.TriggerManual || !c.Input.Force || len(c.Input.Only) != 1 {
		t.Errorf("call = %+v", c)
	}
}

func TestExecutor_BuiltinInlineRespectsConcurrency(t *testing.T) {
	f := builtinFixture(t, nil)
	a := f.seedBuiltin(t, builtinRecipeText(`return 1;`, "", "builtin:brief.compose"), true)
	first := f.enqueue(t, a, db.TriggerSync)
	f.claimAt(t, a, first, exStart)
	second := f.enqueue(t, a, db.TriggerManual)
	if _, err := f.e.ExecuteBuiltinInline(context.Background(), second); !errors.Is(err, automations.ErrRunNotClaimed) {
		t.Fatalf("err = %v; want ErrRunNotClaimed", err)
	}
	if r := f.run(t, second); r.Status != db.RunQueued {
		t.Errorf("second run = %s; want queued", r.Status)
	}
}

func TestBuiltinSDK_MalformedInputFailsBeforeTheScript(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"});`, "", "builtin:brief.compose"), true)
	for _, ev := range []string{`{"builtin":`, `{"builtin":{"date":"20.10.2026"}}`, `{"builtin":{"only":["brief.compose","weekly.digest"]}}`} {
		r := f.runBuiltin(t, a, db.TriggerSync, ev)
		if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindBackend {
			t.Errorf("%s: run = %s/%s (%s)", ev, r.Status, r.ErrorKind, r.Error)
		}
	}
	if p.count() != 0 {
		t.Errorf("primitive called %d times", p.count())
	}
}

func TestConfirmedRecipe_BuiltinRow(t *testing.T) {
	f := builtinFixture(t, nil)
	a := f.seedBuiltin(t, builtinRecipeText(`return 1;`, "", "builtin:brief.compose"), true)
	r, err := automations.ConfirmedRecipe(f.d, &a)
	if err != nil || r == nil {
		t.Fatalf("ConfirmedRecipe = %v, %v", r, err)
	}
	if !r.Scope.IsBuiltin() || r.Trigger.Kind != automations.TriggerSync {
		t.Errorf("recipe scope %s trigger %+v", r.Scope, r.Trigger)
	}
	if s := automations.ScopeOf(a); s.String() != "builtin:"+testBuiltinID {
		t.Errorf("ScopeOf = %s", s)
	}
}

func TestBuiltinSDK_UnknownPrimitiveStatusFailsAsPrimitiveFailed(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "maybe"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"brief.compose": p})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"}); return "end";`, "", "builtin:brief.compose"), true)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindBackend || !strings.Contains(r.Error, automations.ErrNamePrimitiveFailed) ||
		!strings.Contains(r.Error, `"maybe"`) {
		t.Errorf("run = %s/%s (%s)", r.Status, r.ErrorKind, r.Error)
	}
}

func TestExecutor_PollNeverResumesBuiltinRuns(t *testing.T) {
	f := builtinFixture(t, nil)
	a := f.seedBuiltin(t, builtinRecipeText(`return 1;`, "", "builtin:brief.compose"), true)
	if err := f.d.SetBuiltinEnabled(testBuiltinID, true, exStart); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerSync)
	f.claimAt(t, a, id, exStart)
	if err := f.d.SetAutomationRunWaiting(id, db.WaitApp); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`UPDATE automation_runs SET resume_pending = 1 WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	f.step(t, 0)
	// Unrunnable now: still neither resumed nor ended by the poll.
	f.seedBuiltin(t, builtinRecipeText(`log(1);`, "", "builtin:brief.compose"), false)
	f.step(t, 0)
	if r := f.run(t, id); r.Status != db.RunWaiting {
		t.Errorf("run = %s/%s (%s); want waiting", r.Status, r.ErrorKind, r.Error)
	}
}

// watchRecipeText is a Personal watch recipe (trigger sync custom_tracks)
// with track:scan and the extra permissions given.
func watchRecipeText(script string, perms ...string) string {
	var p strings.Builder
	for _, e := range append([]string{"track:scan"}, perms...) {
		p.WriteString("  - " + e + "\n")
	}
	return "---\nname: Watch acme\ntrigger:\n  sync: custom_tracks\npermissions:\n" + p.String() +
		"---\nA watch test recipe.\n\n```js\n" + script + "\n```\n"
}

// seedWatch indexes slug as a Personal watch recipe; unless unconfirmed it
// is confirmed and enabled.
func (f *exFixture) seedWatch(t *testing.T, slug, script string, unconfirmed bool, perms ...string) db.Automation {
	t.Helper()
	a := f.seedText(t, slug, watchRecipeText(script, perms...), unconfirmed)
	if a.ParseError != "" || !a.RunsAtSlot() {
		t.Fatalf("watch recipe %s: parse error %q, runs at slot %v", slug, a.ParseError, a.RunsAtSlot())
	}
	return a
}

func TestExecutor_PollNeverClaimsWatchRecipeRuns(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `track.scan({instruction: "acme launch"});`, false)
	if !a.Runnable() {
		t.Fatalf("watch recipe not runnable: %+v", a)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 0)
	if r := f.run(t, id); r.Status != db.RunQueued || p.count() != 0 {
		t.Errorf("run = %s, primitive calls %d; want queued and none", r.Status, p.count())
	}
}

func TestExecutor_InlineRunsWatchRecipeOnlyWhenEnabled(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done", Fields: map[string]any{"events": 2}}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `return track.scan({instruction: "acme launch"}).events;`, false)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != "2" || p.count() != 1 {
		t.Fatalf("enabled: run = %s %q (%s), calls %d", r.Status, r.Summary, r.Error, p.count())
	}
	if err := f.d.SetAutomationEnabled(a.ID, false, exStart); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	if _, err := f.e.ExecuteBuiltinInline(context.Background(), id); !errors.Is(err, automations.ErrNotRunnable) {
		t.Fatalf("disabled: err = %v; want ErrNotRunnable", err)
	}
	f.wantRun(t, id, db.RunCancelled, db.ErrKindNotRunnable)
	if p.count() != 1 {
		t.Errorf("primitive called %d times; want 1", p.count())
	}
}

func TestAuto06_InlineRefusesUnconfirmedWatchRecipe(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `track.scan({instruction: "acme launch"});`, true)
	if a.Confirmed() {
		t.Fatal("the seeded watch recipe is confirmed")
	}
	id := f.enqueue(t, a, db.TriggerManual)
	if _, err := f.e.ExecuteBuiltinInline(context.Background(), id); !errors.Is(err, automations.ErrNotRunnable) {
		t.Fatalf("err = %v; want ErrNotRunnable", err)
	}
	f.wantRun(t, id, db.RunCancelled, db.ErrKindNotRunnable)
	if p.count() != 0 {
		t.Errorf("primitive called %d times", p.count())
	}
}

func TestTrackSDK_InstalledOnlyWithCapability(t *testing.T) {
	f := builtinFixture(t, nil)
	plain := f.seed(t, "plain", `return [typeof track, typeof tracks].join(",");`, false)
	id := f.enqueue(t, plain, db.TriggerManual)
	f.step(t, 1)
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != "undefined,undefined" {
		t.Errorf("plain: summary = %q", r.Summary)
	}
	w := f.seedWatch(t, "watch",
		`return [typeof track, typeof track.scan, typeof tracks, typeof ideas, typeof reaction, typeof builtin].join(",");`, false)
	if r := f.runBuiltin(t, w, db.TriggerSync, ""); r.Status != db.RunSucceeded ||
		r.Summary != "object,function,undefined,undefined,undefined,undefined" {
		t.Errorf("watch: run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	b := f.seedBuiltin(t, builtinRecipeText(`return [typeof tracks, typeof tracks.extract, typeof track].join(",");`,
		"", "builtin:tracks.extract"), true)
	if r := f.runBuiltin(t, b, db.TriggerSync, ""); r.Status != db.RunSucceeded || r.Summary != "object,function,undefined" {
		t.Errorf("built-in: run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
}

func TestTrackSDK_SinceComesFromInputOnly(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done", Fields: map[string]any{"events": 0}}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `let caught = "";
try { track.scan({instruction: "acme", since: "2026-01-01T00:00:00Z"}); } catch (e) { caught = e.name; }
return caught + ":" + track.scan({instruction: "acme"}).status;`, false)
	r := f.runBuiltin(t, a, db.TriggerManual, `{"builtin":{"since":"2026-10-01T00:00:00Z"}}`)
	if r.Status != db.RunSucceeded || r.Summary != automations.ErrNameValidation+":done" {
		t.Fatalf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	if p.count() != 1 {
		t.Fatalf("primitive called %d times; want 1", p.count())
	}
	if c := p.calls[0]; c.Name != "track.scan" || c.Input.Since != "2026-10-01T00:00:00Z" || c.Prompt != "acme" ||
		c.Trigger.Kind != db.TriggerManual || len(c.Args) != 0 {
		t.Errorf("call = %+v", c)
	}
	// A since that is not an RFC 3339 instant fails the run before the script.
	r = f.runBuiltin(t, a, db.TriggerManual, `{"builtin":{"since":"2026-10-01"}}`)
	if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindBackend || p.count() != 1 {
		t.Errorf("bad since: run = %s/%s (%s), calls %d", r.Status, r.ErrorKind, r.Error, p.count())
	}
}

func TestTrackSDK_ExtraIsCapped(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "done", Fields: map[string]any{"events": 0}}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `const item = (i) => ({source_type: "slack", source_id: "C1:" + i, text: "hi", at: "2026-10-20T09:00:00Z"});
const many = (n) => Array.from({length: n}, (_, i) => item(i));
const out = [];
for (const extra of [many(41), [Object.assign(item(0), {source_type: "fax"})], [Object.assign(item(0), {text: "x".repeat(4097)})],
  [Object.assign(item(0), {at: "yesterday"})], [Object.assign(item(0), {colour: "red"})], [Object.assign(item(0), {source_id: ""})],
  "not an array", many(40)]) {
  try { track.scan({instruction: "acme", extra}); out.push("ok"); } catch (e) { out.push(e.name); }
}
return out.join(",");`, false)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	want := strings.Repeat(automations.ErrNameValidation+",", 7) + "ok"
	if r.Status != db.RunSucceeded || r.Summary != want {
		t.Fatalf("run = %s %q (%s); want %q", r.Status, r.Summary, r.Error, want)
	}
	if p.count() != 1 {
		t.Fatalf("primitive called %d times; want 1", p.count())
	}
	extra, ok := p.calls[0].Args["extra"].([]automations.TrackScanItem)
	if !ok || len(extra) != 40 {
		t.Fatalf("extra = %#v", p.calls[0].Args["extra"])
	}
	if want := (automations.TrackScanItem{SourceType: "slack", SourceID: "C1:3", Text: "hi", At: "2026-10-20T09:00:00Z"}); extra[3] != want {
		t.Errorf("extra[3] = %+v; want %+v", extra[3], want)
	}
}

func TestTrackSDK_StepPermissionIsTrackScan(t *testing.T) {
	p := &fakePrimitive{res: automations.PrimitiveResult{Status: "skipped"}}
	f := builtinFixture(t, map[string]*fakePrimitive{"track.scan": p})
	a := f.seedWatch(t, "watch", `return track.scan({instruction: "acme"}).status;`, false)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != "skipped" {
		t.Fatalf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	steps := f.steps(t, r.ID)
	if len(steps) != 1 || steps[0].Kind != automations.StepKindLLM || steps[0].Name != "track.scan" ||
		steps[0].Permission != "track:scan" || steps[0].Status != automations.StepOK ||
		!strings.Contains(steps[0].ArgsJSON, `"instruction":"acme"`) {
		t.Errorf("steps = %+v", steps)
	}
}
