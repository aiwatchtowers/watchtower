package automations

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// sbClock is a minimal fake Clock (automationstest.FakeClock arrives with
// the SDK modules).
type sbClock struct {
	mu  sync.Mutex
	now time.Time
}

func newSBClock() *sbClock { return &sbClock{now: time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)} }

func (c *sbClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *sbClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

func (c *sbClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// funcModule defines each path of fns.
type funcModule struct {
	name string
	fns  map[string]SDKFunc
}

func (m funcModule) Name() string { return m.name }

func (m funcModule) Install(def Definer) {
	for p, fn := range m.fns {
		def.Define(p, fn)
	}
}

// testModule defines echo, big, boom, deny, spend and refuse.
func testModule() Module {
	return funcModule{name: "test", fns: map[string]SDKFunc{
		"echo": func(env *Env, call goja.FunctionCall, _ *goja.Runtime) (any, error) {
			return env.Call("tool", "echo", call.Argument(0).Export(), func(*Step) (any, error) {
				return call.Argument(0).Export(), nil
			})
		},
		"big": func(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			return env.Call("tool", "big", nil, func(*Step) (any, error) {
				return strings.Repeat("x", 257*1024), nil
			})
		},
		"boom": func(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			return env.Call("tool", "boom", nil, func(*Step) (any, error) {
				return nil, &SDKError{Name: ErrNameTool, Message: "the backend failed"}
			})
		},
		"deny": func(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			return env.Call("tool", "deny", nil, func(*Step) (any, error) {
				return nil, &PermissionDenied{Needed: "jira:read@OPS", Cause: errors.New("internal detail")}
			})
		},
		"spend": func(env *Env, call goja.FunctionCall, _ *goja.Runtime) (any, error) {
			env.Meter.Debit(call.Argument(0).ToInteger(), 0)
			return nil, nil
		},
		"refuse": func(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			return nil, env.Meter.BeforeCall()
		},
		"crash": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			panic("a Go bug inside an SDK function")
		},
	}}
}

type sbOpts struct {
	budget     Budget
	daily      int64
	clock      Clock
	trigger    TriggerInfo
	scriptLine int
	modules    []Module
	journal    *Journal
}

func newTestSandbox(t *testing.T, script string, o sbOpts) (*Sandbox, *Env) {
	t.Helper()
	if o.budget == (Budget{}) {
		o.budget = Budget{Tokens: 50000, Minutes: 5}
	}
	if o.daily == 0 {
		o.daily = math.MaxInt64
	}
	if o.clock == nil {
		o.clock = RealClock{}
	}
	if o.modules == nil {
		o.modules = []Module{testModule()}
	}
	if o.journal == nil {
		o.journal = NewMemoryJournal()
	}
	env := &Env{
		Ctx:     context.Background(),
		Recipe:  &Recipe{Script: script, ScriptLine: o.scriptLine},
		Journal: o.journal,
		Meter:   NewMeter(o.budget, o.daily, o.clock),
		Buffer:  NewCommitBuffer(nil),
		Trigger: o.trigger,
	}
	sb, err := NewSandbox(env, o.modules)
	if err != nil {
		t.Fatalf("NewSandbox: %v", err)
	}
	return sb, env
}

func runScript(t *testing.T, script string, o sbOpts) (any, error) {
	t.Helper()
	sb, _ := newTestSandbox(t, script, o)
	return sb.Run()
}

func mustRun(t *testing.T, script string, o sbOpts) any {
	t.Helper()
	v, err := runScript(t, script, o)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return v
}

func wantInterrupt(t *testing.T, err error, want InterruptReason) {
	t.Helper()
	var ri *RunInterrupted
	if !errors.As(err, &ri) || ri.Reason != want {
		t.Fatalf("Run error = %v; want interrupt %q", err, want)
	}
}

func TestAuto07_NoRequireFsNetTimers(t *testing.T) {
	got := mustRun(t, `return [typeof require, typeof console, typeof setTimeout, typeof setInterval,
		typeof fetch, typeof XMLHttpRequest, typeof process, typeof module, typeof globalThis.Promise].join(",")`, sbOpts{})
	want := strings.TrimSuffix(strings.Repeat("undefined,", 9), ",")
	if got != want {
		t.Fatalf("typeofs = %v; want %v", got, want)
	}
}

func TestRecipe_AsyncScriptRefused(t *testing.T) {
	line, msg := wantParseError(t, recipeWith(baseFrontmatter, "const a = 1;\nawait x;\n"), "the script API is synchronous")
	if line != 10 { // script starts on file line 9
		t.Errorf("line = %d (%s); want 10", line, msg)
	}
}

func TestSandbox_PreParseRefusesAsync(t *testing.T) {
	refused := map[string]string{
		"async function f(){}":           "async",
		"const v = await x;":             "await",
		"new Promise(function(r){r()});": "Promise",
		"setTimeout(f, 1);":              "setTimeout",
		"setInterval(f, 1);":             "setInterval",
		"const s = `a ${await x} b`;":    "await",
		"const f = async () => 1;":       "async",
		"const p = ...Promise;":          "Promise",
		"mytypeof Promise":               "Promise",
	}
	for src, word := range refused {
		var pe *PreParseError
		if err := PreParse(src); !errors.As(err, &pe) || pe.Word != word ||
			!strings.Contains(err.Error(), "the script API is synchronous") {
			t.Errorf("PreParse(%q) = %v; want a refusal of %q", src, err, word)
		}
	}
	allowed := []string{
		`log("await the reply, then Promise it");`,
		"// setTimeout is not here\n/* async */ return 1;",
		"const s = `no ${'await'} here`;",
		"const a = obj.async; const b = { async: 1, setTimeout : 2 };",
		"const asyncish = 1; const awaited = 2;",
		"if (typeof setTimeout === 'undefined' && typeof  Promise !== 'function') {}",
		"",
	}
	for _, src := range allowed {
		if err := PreParse(src); err != nil {
			t.Errorf("PreParse(%q) = %v; want nil", src, err)
		}
	}
}

func TestSandbox_PreParseReportsTheScriptLine(t *testing.T) {
	var pe *PreParseError
	if err := PreParse("const a = 'x\\\ny';\n// c\n\nsetTimeout(f)"); !errors.As(err, &pe) || pe.Line != 5 {
		t.Fatalf("PreParse = %v; want line 5", err)
	}
	if _, err := NewSandbox(&Env{Ctx: context.Background(), Recipe: &Recipe{Script: "await x"},
		Journal: NewMemoryJournal(), Meter: NewMeter(Budget{Tokens: 1, Minutes: 1}, 1, nil)}, nil); !errors.As(err, &pe) {
		t.Fatalf("NewSandbox = %v; want a *PreParseError", err)
	}
}

func TestAuto08_InterruptOnTimeout(t *testing.T) {
	clock := newSBClock()
	sb, _ := newTestSandbox(t, "while (true) {}", sbOpts{budget: Budget{Tokens: 50000, Minutes: 1}, clock: clock})
	clock.Advance(59 * time.Second) // one real second of the deadline is left
	start := time.Now()
	_, err := sb.Run()
	wantInterrupt(t, err, InterruptTimeout)
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("Run took %v; want < 2s", took)
	}
}

func TestSandbox_InterruptIsNotCatchable(t *testing.T) {
	cases := []struct {
		name, script string
		budget       Budget
		external     bool
	}{
		{"external interrupt", "while (true) { try { echo(1) } catch (e) {} }", Budget{}, true},
		{"debit crosses the budget", "while (true) { try { spend(30000) } catch (e) {} }", Budget{}, false},
		{"spent budget refuses and the catch does not help",
			"while (true) { try { refuse() } catch (e) {} finally {} }", Budget{Tokens: 0, Minutes: 5}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sb, _ := newTestSandbox(t, c.script, sbOpts{budget: c.budget})
			if c.external {
				time.AfterFunc(50*time.Millisecond, func() { sb.Interrupt(InterruptBudget) })
			}
			_, err := runWithin(t, sb, 5*time.Second)
			wantInterrupt(t, err, InterruptBudget)
		})
	}
}

func TestSandbox_DailyCapInterruptsUncatchably(t *testing.T) {
	sb, _ := newTestSandbox(t, "while (true) { try { spend(10) } catch (e) {} }", sbOpts{daily: 25})
	_, err := runWithin(t, sb, 5*time.Second)
	wantInterrupt(t, err, InterruptDailyCap)
	_, err = runScript(t, "try { refuse() } catch (e) {} return 1", sbOpts{daily: -1})
	wantInterrupt(t, err, InterruptDailyCap)
}

func runWithin(t *testing.T, sb *Sandbox, limit time.Duration) (any, error) {
	t.Helper()
	type res struct {
		v   any
		err error
	}
	ch := make(chan res, 1)
	go func() {
		v, err := sb.Run()
		ch <- res{v, err}
	}()
	select {
	case r := <-ch:
		return r.v, r.err
	case <-time.After(limit):
		sb.Interrupt(InterruptCancel)
		<-ch
		t.Fatalf("Run did not stop within %v", limit)
		return nil, nil
	}
}

func TestSandbox_ResultTooLargeIsAnErrorNotATruncation(t *testing.T) {
	sb, env := newTestSandbox(t, `try { big(); return "no error" } catch (e) { return e.name }`, sbOpts{})
	got, err := sb.Run()
	if err != nil || got != ErrNameResultTooLarge {
		t.Fatalf("Run = %v, %v; want %q", got, err, ErrNameResultTooLarge)
	}
	steps := env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != StepError || steps[0].FinishedAt == nil ||
		!strings.Contains(steps[0].Error, "limit") {
		t.Fatalf("steps = %+v; want one closed error step", steps)
	}
}

func TestSandbox_SDKErrorHasName(t *testing.T) {
	got := mustRun(t, `var out = [];
		try { boom() } catch (e) { out.push(e.name, e.message, e instanceof Error) }
		try { deny() } catch (e) { out.push(e.name, e.needed, e.message) }
		return out.join("|")`, sbOpts{})
	want := "ToolError|the backend failed|true|PermissionDenied|jira:read@OPS|permission denied: the recipe needs jira:read@OPS"
	if got != want {
		t.Fatalf("got %q; want %q", got, want)
	}
}

func TestSandbox_DeniedCallWritesDeniedStep(t *testing.T) {
	sb, env := newTestSandbox(t, `try { deny() } catch (e) {}`, sbOpts{})
	if _, err := sb.Run(); err != nil {
		t.Fatal(err)
	}
	steps := env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != StepDenied || steps[0].Permission != "jira:read@OPS" {
		t.Fatalf("steps = %+v", steps)
	}
}

func TestSandbox_UncaughtSDKErrorKeepsItsName(t *testing.T) {
	_, err := runScript(t, "\ndeny()\n", sbOpts{scriptLine: 20})
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != ErrNamePermissionDenied || se.Line != 21 {
		t.Fatalf("Run error = %#v; want an uncaught PermissionDenied on line 21", err)
	}
}

func TestSandbox_ErrorLineMapsToFile(t *testing.T) {
	_, err := runScript(t, "const a = 1;\nconst b = 2;\nthrow new Error('broken');\n", sbOpts{scriptLine: 12})
	var se *ScriptError
	if !errors.As(err, &se) {
		t.Fatalf("Run error = %v; want *ScriptError", err)
	}
	if se.Line != 14 || se.Name != "Error" || se.Message != "broken" || !strings.Contains(se.Stack, "line 14") {
		t.Fatalf("ScriptError = %+v; want Error 'broken' on line 14", se)
	}
}

func TestSandbox_SyntaxErrorLineMapsToFile(t *testing.T) {
	sbEnv := &Env{Ctx: context.Background(), Recipe: &Recipe{Script: "const a = 1;\nconst = ;\n", ScriptLine: 5},
		Journal: NewMemoryJournal(), Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, math.MaxInt64, nil)}
	_, err := NewSandbox(sbEnv, nil)
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != "SyntaxError" || se.Line != 6 {
		t.Fatalf("NewSandbox error = %#v; want a SyntaxError on line 6", err)
	}
}

func TestSandbox_TriggerIsReadOnly(t *testing.T) {
	got := mustRun(t, `var threw = false;
		try { trigger.kind = "x" } catch (e) { threw = e instanceof TypeError }
		try { trigger = {} } catch (e) {}
		return [threw, trigger.kind, trigger.run_id, trigger.dry_run, trigger.catch_up,
			typeof trigger.button, trigger.scheduled_for].join(",")`,
		sbOpts{trigger: TriggerInfo{Kind: "schedule", RunID: 7, DryRun: true,
			ScheduledFor: ptrTime(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))}})
	if got != "true,schedule,7,true,false,undefined,2026-10-14T09:00:00Z" {
		t.Fatalf("got %q", got)
	}
}

func ptrTime(t time.Time) *time.Time { return &t }

func TestSandbox_TriggerEventsAreReadOnly(t *testing.T) {
	events := []map[string]any{{"channel": "releases", "nested": map[string]any{"a": 1}}}
	got := mustRun(t, `var threw = 0;
		try { trigger.events.push(1) } catch (e) { threw++ }
		try { trigger.events[0].nested.a = 2 } catch (e) { threw++ }
		return [threw, trigger.events.length, trigger.events[0].nested.a, trigger.truncated].join(",")`,
		sbOpts{trigger: TriggerInfo{Kind: "event", Events: events, Truncated: true}})
	if got != "2,1,1,true" {
		t.Fatalf("got %q", got)
	}
	got = mustRun(t, `return typeof trigger.events + "," + trigger.truncated`, sbOpts{trigger: TriggerInfo{Kind: "manual"}})
	if got != "undefined,false" {
		t.Fatalf("no events: got %q", got)
	}
}

func TestDefiner_LaterModuleReplacesPath(t *testing.T) {
	returns := func(v any) SDKFunc {
		return func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) { return v, nil }
	}
	a := funcModule{name: "a", fns: map[string]SDKFunc{"echo": returns(1), "only.a": returns("a")}}
	b := funcModule{name: "b", fns: map[string]SDKFunc{"echo": returns(2), "only.b": returns("b")}}
	got := mustRun(t, `return echo() + "," + only.a() + "," + only.b()`, sbOpts{modules: []Module{a, b}})
	if got != "2,a,b" {
		t.Fatalf("got %q; want 2,a,b", got)
	}
}

func TestDefiner_InvalidPathRefused(t *testing.T) {
	bad := funcModule{name: "bad", fns: map[string]SDKFunc{"state..get": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
		return nil, nil
	}}}
	env := &Env{Ctx: context.Background(), Recipe: &Recipe{Script: "1"}, Journal: NewMemoryJournal(),
		Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, math.MaxInt64, nil)}
	if _, err := NewSandbox(env, []Module{bad}); err == nil || !strings.Contains(err.Error(), "state..get") {
		t.Fatalf("NewSandbox = %v; want an invalid path error", err)
	}
}

func TestSandbox_GoPanicEndsRunUncatchably(t *testing.T) {
	_, err := runScript(t, `try { crash() } catch (e) {} return "continued"`, sbOpts{})
	if !errors.Is(err, ErrSDKPanic) || !strings.Contains(err.Error(), "crash") {
		t.Fatalf("Run error = %v; want ErrSDKPanic naming crash", err)
	}
}

func TestSandbox_RunawayRecursionIsAnError(t *testing.T) {
	_, err := runScript(t, `function f() { try { return f() } catch (e) { return 0 } } return f()`, sbOpts{})
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != "RangeError" {
		t.Fatalf("Run error = %v; want an uncatchable RangeError", err)
	}
}

func TestSandbox_ReturnValuesAndResults(t *testing.T) {
	if got := mustRun(t, "", sbOpts{}); got != nil {
		t.Errorf("empty script = %v; want nil", got)
	}
	got := mustRun(t, `var r = echo({a: [1, "x"]}); return JSON.stringify(r) + "," + typeof echo()`, sbOpts{})
	if got != `{"a":[1,"x"]},undefined` {
		t.Errorf("got %v", got)
	}
	sb, _ := newTestSandbox(t, "return 1", sbOpts{})
	if _, err := sb.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := sb.Run(); err == nil {
		t.Error("second Run: want an error")
	}
}

func TestSandbox_ParentCancelInterrupts(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	env := &Env{Ctx: ctx, Recipe: &Recipe{Script: "while (true) {}"}, Journal: NewMemoryJournal(),
		Meter: NewMeter(Budget{Tokens: 1000, Minutes: 5}, math.MaxInt64, nil)}
	sb, err := NewSandbox(env, nil)
	if err != nil {
		t.Fatal(err)
	}
	time.AfterFunc(50*time.Millisecond, cancel)
	_, err = runWithin(t, sb, 5*time.Second)
	wantInterrupt(t, err, InterruptCancel)
	if env.Ctx.Err() == nil {
		t.Error("Env.Ctx was not cancelled")
	}
}

func TestSandbox_NewSandboxNeedsEnv(t *testing.T) {
	for name, env := range map[string]*Env{
		"nil env":    nil,
		"no meter":   {Ctx: context.Background(), Recipe: &Recipe{}, Journal: NewMemoryJournal()},
		"no journal": {Ctx: context.Background(), Recipe: &Recipe{}, Meter: NewMeter(Budget{}, 0, nil)},
	} {
		if _, err := NewSandbox(env, nil); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestEnv_Binding(t *testing.T) {
	env := &Env{Run: &db.AutomationRun{ID: 42}, Automation: &db.Automation{ProjectID: 3}}
	want := tools.Binding{Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType,
		ContextID: "42", WorkbenchID: 3}
	if got := env.Binding(); got.Surface != want.Surface || got.ContextType != want.ContextType ||
		got.ContextID != want.ContextID || got.WorkbenchID != want.WorkbenchID {
		t.Fatalf("Binding = %+v; want %+v", got, want)
	}
	draft := &Env{Run: &db.AutomationRun{}, Recipe: &Recipe{Scope: Scope{Kind: ScopeWorkbench, WorkbenchID: 9}}}
	if got := draft.Binding(); got.ContextID != "0" || got.WorkbenchID != 9 {
		t.Fatalf("draft Binding = %+v", got)
	}
}

// --- journal ---

func seedJournalRun(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d := openManifestTestDB(t)
	id, err := d.UpsertAutomationIndex(db.Automation{Slug: "j", Scope: "personal", Path: "/automations/j.md", Name: "J", TriggerKind: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	run, _, err := d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: id, Trigger: db.TriggerManual, Now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	return d, run
}

func TestJournal_MarkIsNonFinalAndKeepsLink(t *testing.T) {
	d, run := seedJournalRun(t)
	j := NewJournal(d, run, false)
	s := j.Begin("tool", "create_target", map[string]any{"title": "x"})
	if err := s.Mark(StepWaiting, db.StepFinish{ActionID: 7}); err != nil {
		t.Fatal(err)
	}
	rows := mustSteps(t, d, run)
	if len(rows) != 1 || rows[0].ID != s.ID() || rows[0].Status != StepWaiting || rows[0].ActionID != 7 || rows[0].FinishedAt != nil {
		t.Fatalf("after Mark: %+v (step id %d)", rows, s.ID())
	}
	s.OK(map[string]any{"status": "applied"})
	rows = mustSteps(t, d, run)
	if rows[0].Status != StepOK || rows[0].ActionID != 7 || rows[0].FinishedAt == nil || rows[0].ResultSummary != `{"status":"applied"}` {
		t.Fatalf("after OK: %+v", rows[0])
	}
	if err := s.Mark(StepWaiting, db.StepFinish{}); !errors.Is(err, db.ErrStepFinished) {
		t.Fatalf("Mark after OK = %v; want ErrStepFinished", err)
	}
	if err := j.Err(); err != nil {
		t.Fatalf("journal Err = %v", err)
	}
}

func mustSteps(t *testing.T, d *db.DB, run int64) []db.AutomationRunStep {
	t.Helper()
	rows, err := d.ListAutomationRunSteps(run)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestJournal_UsageAddsToRunAndStep(t *testing.T) {
	d, run := seedJournalRun(t)
	j := NewJournal(d, run, false)
	s := j.Begin("llm", "light", "prompt")
	cost := 0.25
	s.Usage(100, 50, false, &cost)
	s.Usage(10, 0, true, nil)
	s.SetPermission("llm:light")
	s.OK("reply")
	r, err := d.GetAutomationRun(run)
	if err != nil {
		t.Fatal(err)
	}
	if r.InputTokens != 110 || r.OutputTokens != 50 || !r.TokensEstimated || r.ReportedCostUSD == nil || *r.ReportedCostUSD != 0.25 {
		t.Fatalf("run usage = %d/%d est=%v cost=%v", r.InputTokens, r.OutputTokens, r.TokensEstimated, r.ReportedCostUSD)
	}
	row := mustSteps(t, d, run)[0]
	if row.InputTokens != 110 || row.OutputTokens != 50 || !row.TokensEstimated || row.Permission != "llm:light" {
		t.Fatalf("step = %+v", row)
	}
	if tot := j.Totals(); tot.InputTokens != 110 || tot.OutputTokens != 50 {
		t.Fatalf("totals = %+v", tot)
	}
}

func TestJournal_WriteErrorIsKept(t *testing.T) {
	d, _ := seedJournalRun(t)
	j := NewJournal(d, 999, false) // no such run: the insert fails its FK
	s := j.Begin("log", "", "x")
	s.OK(nil)
	if j.Err() == nil || s.ID() != 0 || j.Count() != 1 {
		t.Fatalf("Err = %v, id = %d, count = %d; want a kept error", j.Err(), s.ID(), j.Count())
	}
}

func TestMemoryJournal_WritesNoRows(t *testing.T) {
	j := NewMemoryJournal()
	a := j.Begin("tool", "list_emails", map[string]any{"q": strings.Repeat("é", 3000)})
	if err := a.Mark(StepWaiting, db.StepFinish{AskID: 4}); err != nil {
		t.Fatal(err)
	}
	a.OK([]int{1})
	b := j.Begin("tool", "list_jira_issues", nil)
	b.Denied("jira:read@OPS")
	c := j.Begin("state", "set", "k")
	c.Finish(db.StepFinish{Status: StepDryRun})
	if got := []int64{int64(j.Count()), a.ID(), b.ID(), c.ID()}; !slices.Equal(got, []int64{3, 1, 2, 3}) {
		t.Fatalf("count and ids = %v; want [3 1 2 3]", got)
	}
	wantMemorySteps(t, j.Steps(), []string{StepOK, StepDenied, StepDryRun})
	steps := j.Steps()
	if steps[0].AskID != 4 || len(steps[0].ArgsJSON) > StepClipBytes || steps[1].Permission != "jira:read@OPS" {
		t.Errorf("step details = %+v / %+v", steps[0], steps[1])
	}
	if !j.DryRun() || j.Err() != nil {
		t.Errorf("DryRun = %v, Err = %v", j.DryRun(), j.Err())
	}
}

// wantMemorySteps checks seq, id = seq, status and that every step is closed.
func wantMemorySteps(t *testing.T, steps []db.AutomationRunStep, statuses []string) {
	t.Helper()
	if len(steps) != len(statuses) {
		t.Fatalf("steps = %d; want %d", len(steps), len(statuses))
	}
	for i, s := range steps {
		if s.Seq != i+1 || s.ID != int64(i+1) || s.Status != statuses[i] || s.FinishedAt == nil {
			t.Errorf("step %d = %+v", i, s)
		}
	}
}

func TestJournal_ClipsArgsAndResult(t *testing.T) {
	d, run := seedJournalRun(t)
	j := NewJournal(d, run, false)
	big := strings.Repeat("a", 10*1024)
	s := j.Begin("tool", "echo", big)
	s.OK(big)
	f := j.Begin("tool", "boom", nil)
	f.Fail(errors.New(big))
	rows := mustSteps(t, d, run)
	if len(rows[0].ArgsJSON) != StepClipBytes || len(rows[0].ResultSummary) != StepClipBytes || len(rows[1].Error) != StepClipBytes {
		t.Fatalf("clipped lengths = %d/%d/%d; want %d", len(rows[0].ArgsJSON), len(rows[0].ResultSummary),
			len(rows[1].Error), StepClipBytes)
	}
	if got := clipUTF8("aé", 2); got != "a" {
		t.Errorf("clipUTF8 cut a rune: %q", got)
	}
}

// --- meter ---

func TestMeter_ActiveTimeExcludesPause(t *testing.T) {
	clock := newSBClock()
	start := clock.Now()
	m := NewMeter(Budget{Tokens: 1000, Minutes: 5}, math.MaxInt64, clock)
	clock.Advance(2 * time.Minute)
	m.PauseActive()
	clock.Advance(time.Hour)
	if want := start.Add(5*time.Minute + time.Hour); !m.Deadline().Equal(want) {
		t.Fatalf("deadline while paused = %v; want %v", m.Deadline(), want)
	}
	m.ResumeActive()
	if want := start.Add(5*time.Minute + time.Hour); !m.Deadline().Equal(want) {
		t.Fatalf("deadline = %v; want %v", m.Deadline(), want)
	}
	if got := m.ActiveMS(); got != (2 * time.Minute).Milliseconds() {
		t.Fatalf("ActiveMS = %d; want 2 min", got)
	}
	if got := m.Remaining(); got.Minutes != 3 || got.Tokens != 1000 {
		t.Fatalf("Remaining = %+v; want 3 min, 1000 tokens", got)
	}
	m.ResumeActive() // not paused: no-op
	if m.Paused() {
		t.Fatal("still paused")
	}
}

func TestMeter_BeforeCallRefusesWhenSpent(t *testing.T) {
	m := NewMeter(Budget{Tokens: 1000, Minutes: 5}, math.MaxInt64, nil)
	if err := m.BeforeCall(); err != nil {
		t.Fatalf("fresh BeforeCall = %v", err)
	}
	if crossed := m.Debit(600, 300); crossed != "" {
		t.Fatalf("Debit 900 crossed %q", crossed)
	}
	if crossed := m.Debit(50, 50); crossed != InterruptBudget {
		t.Fatalf("Debit to exactly 0 crossed %q; want budget", crossed)
	}
	var se *SDKError
	if err := m.BeforeCall(); !errors.As(err, &se) || se.Name != ErrNameBudget {
		t.Fatalf("BeforeCall = %v; want BudgetExceeded", err)
	}
	if m.Crossed() != InterruptBudget || m.Remaining().Tokens != 0 {
		t.Fatalf("Crossed = %q, Remaining = %+v", m.Crossed(), m.Remaining())
	}
}

func TestMeter_DailyRemainderInterrupts(t *testing.T) {
	m := NewMeter(Budget{Tokens: 50000, Minutes: 5}, 100, nil)
	if crossed := m.Debit(60, 40); crossed != InterruptDailyCap {
		t.Fatalf("Debit crossed %q; want daily_cap", crossed)
	}
	var ri *RunInterrupted
	if err := m.BeforeCall(); !errors.As(err, &ri) || ri.Reason != InterruptDailyCap {
		t.Fatalf("BeforeCall = %v; want a daily-cap interrupt", err)
	}
	spent := NewMeter(Budget{Tokens: 50000, Minutes: 5}, 0, nil)
	if err := spent.BeforeCall(); !errors.As(err, &ri) || spent.Crossed() != InterruptDailyCap {
		t.Fatalf("spent cap BeforeCall = %v, crossed %q", err, spent.Crossed())
	}
}

// --- commit buffer ---

func TestCommitBuffer_StateTooLarge(t *testing.T) {
	b := NewCommitBuffer(json.RawMessage(`{"keep":1}`))
	var se *SDKError
	if err := b.Set("big", strings.Repeat("x", MaxStateBytes)); !errors.As(err, &se) || se.Name != ErrNameStateTooLarge {
		t.Fatalf("Set = %v; want StateTooLarge", err)
	}
	if _, ok := b.Get("big"); ok {
		t.Fatal("a refused value was buffered")
	}
	if c := b.Commit(); c.StateJSON != nil {
		t.Fatalf("a refused set touched the state: %s", c.StateJSON)
	}
	if err := b.Set("ok", strings.Repeat("x", MaxStateBytes-100)); err != nil {
		t.Fatalf("Set under the limit = %v", err)
	}
}

func TestCommitBuffer_UntouchedStateCommitsNil(t *testing.T) {
	b := NewCommitBuffer(json.RawMessage(`{"since":"2026-10-01"}`))
	if v, ok := b.Get("since"); !ok || v != "2026-10-01" {
		t.Fatalf("Get = %v, %v", v, ok)
	}
	if err := b.AddOutput(db.AutomationOutput{Kind: "inbox", Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}
	c := b.Commit()
	if c.StateJSON != nil || len(c.Outputs) != 1 {
		t.Fatalf("Commit = %+v; want nil state and one output", c)
	}
	if err := b.Set("since", "2026-10-14"); err != nil {
		t.Fatal(err)
	}
	if got := string(b.Commit().StateJSON); got != `{"since":"2026-10-14"}` {
		t.Fatalf("StateJSON = %s", got)
	}
	if all := b.All(); len(all) != 1 || all["since"] != "2026-10-14" {
		t.Fatalf("All = %v", all)
	}
}

func TestCommitBuffer_RejectsUnserialisableValues(t *testing.T) {
	cyclic := map[string]any{}
	cyclic["self"] = cyclic
	for name, v := range map[string]any{
		"function": func() {}, "NaN": math.NaN(), "Infinity": math.Inf(1), "cycle": cyclic,
		"BigInt": big.NewInt(1), "nested BigInt": []any{map[string]any{"n": big.NewInt(2)}},
	} {
		b := NewCommitBuffer(nil)
		var se *SDKError
		if err := b.Set("k", v); !errors.As(err, &se) || se.Name != ErrNameValidation {
			t.Errorf("%s: Set = %v; want ValidationError", name, err)
		}
		if b.Commit().StateJSON != nil {
			t.Errorf("%s: buffered", name)
		}
	}
}

func TestCommitBuffer_OutputBodyLimitAndBrokenState(t *testing.T) {
	b := NewCommitBuffer(nil)
	var se *SDKError
	if err := b.AddOutput(db.AutomationOutput{Body: strings.Repeat("x", MaxOutputBodyBytes+1)}); !errors.As(err, &se) ||
		se.Name != ErrNameResultTooLarge {
		t.Fatalf("AddOutput = %v; want ResultTooLarge", err)
	}
	if len(b.Outputs()) != 0 {
		t.Fatal("an oversized output was buffered")
	}
	broken := NewCommitBuffer(json.RawMessage(`[1,2]`))
	if broken.Err() == nil || broken.Set("k", 1) == nil {
		t.Fatal("a state that is not an object must refuse writes")
	}
	if n := NewCommitBuffer(json.RawMessage(`null`)); n.Err() != nil || n.Set("k", 1) != nil {
		t.Fatalf("null state: %v", n.Err())
	}
}
