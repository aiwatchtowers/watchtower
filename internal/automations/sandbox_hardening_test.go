package automations

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dlclark/regexp2/v2"
	"github.com/dop251/goja"

	"watchtower/internal/db"
)

// codeFromStringProbes are the ways a script could compile code from a
// string at run time (and so get past PreParse, e.g. to async functions and
// Promise jobs); each must throw, never run.
var codeFromStringProbes = map[string]string{
	`Function("return a" + "sync function(){}")`: "ReferenceError",
	`eval("1 + 1")`:                                               "ReferenceError",
	`globalThis["ev" + "al"]("1")`:                                "TypeError",
	`(function(){}).constructor("return 1")`:                      "EvalError",
	`(() => 1).constructor("return 1")`:                           "EvalError",
	`(function*(){}).constructor("yield 1")`:                      "EvalError",
	`Object.getPrototypeOf(function(){}).constructor("return 1")`: "EvalError",
	`Reflect.construct((function(){}).constructor, ["return 1"])`: "EvalError",
	`(class {}).constructor("return 1")`:                          "EvalError",
	`(function(){}).bind(null).constructor("return 1")`:           "EvalError",
	`new ((function(){}).constructor.constructor)("return 1")`:    "EvalError",
	`Object.getOwnPropertyDescriptor(Function.prototype, "x")`:    "ReferenceError",
	`[].constructor.constructor("return 1")`:                      "EvalError",
	`({}).toString.constructor("return 1")`:                       "EvalError",
	`Symbol.constructor("return 1")`:                              "EvalError",
	`trigger.constructor.constructor("return 1")`:                 "EvalError",
}

func TestAuto07_NoCodeFromStrings(t *testing.T) {
	for probe, want := range codeFromStringProbes {
		got := mustRun(t, "try { "+probe+"; return 'ran' } catch (e) { return e.name }", sbOpts{})
		if got != want {
			t.Errorf("%s → %v; want %s", probe, got, want)
		}
	}
	sb, _ := newTestSandbox(t, "", sbOpts{})
	if _, err := sb.rt.RunString(`Object.getPrototypeOf(async function () {}).constructor("return 1")`); err == nil ||
		!strings.Contains(err.Error(), "EvalError") {
		t.Errorf("the AsyncFunction constructor = %v; want an EvalError", err)
	}
}

func TestSandbox_CatastrophicRegexEndsWithinDeadline(t *testing.T) {
	if regexp2.DefaultMatchTimeout != RegexpMatchTimeout {
		t.Fatalf("regexp2.DefaultMatchTimeout = %v; want %v", regexp2.DefaultMatchTimeout, RegexpMatchTimeout)
	}
	clock := newSBClock()
	sb, _ := newTestSandbox(t, `return /(a+)+b(?=c)/.test("a".repeat(33))`,
		sbOpts{budget: Budget{Tokens: 1000, Minutes: 1}, clock: clock})
	clock.Advance(59 * time.Second)
	start := time.Now()
	_, err := sb.Run()
	wantInterrupt(t, err, InterruptTimeout)
	if took := time.Since(start); took > time.Second+AbandonGrace+time.Second {
		t.Fatalf("Run took %v", took)
	}
	waitNoAbandonedRuns(t)
}

// stuckModule defines `stuck`, a native call that ignores its context for
// stuckFor (as a long builtin would).
func stuckModule(stuckFor time.Duration) Module {
	return funcModule{name: "stuck", fns: map[string]SDKFunc{
		"stuck": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			time.Sleep(stuckFor)
			return nil, nil
		},
	}}
}

func waitNoAbandonedRuns(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for AbandonedRuns() > 0 {
		if time.Now().After(deadline) {
			t.Fatalf("AbandonedRuns = %d after 30 s", AbandonedRuns())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSandbox_StuckNativeIsAbandonedAfterGrace(t *testing.T) {
	waitNoAbandonedRuns(t)
	clock := newSBClock()
	sb, _ := newTestSandbox(t, `while (true) { try { stuck() } catch (e) {} }`,
		sbOpts{budget: Budget{Tokens: 1000, Minutes: 1}, clock: clock, modules: []Module{stuckModule(AbandonGrace + 2*time.Second)}})
	clock.Advance(59*time.Second + 500*time.Millisecond)
	start := time.Now()
	_, err := sb.Run()
	took := time.Since(start)
	var ri *RunInterrupted
	if !errors.As(err, &ri) || ri.Reason != InterruptTimeout || !ri.Abandoned {
		t.Fatalf("Run = %v; want an abandoned timeout", err)
	}
	if took > 500*time.Millisecond+AbandonGrace+500*time.Millisecond {
		t.Fatalf("Run took %v; want deadline + grace", took)
	}
	if AbandonedRuns() != 1 {
		t.Fatalf("AbandonedRuns = %d; want 1", AbandonedRuns())
	}
	waitNoAbandonedRuns(t)
}

func TestSandbox_HugeJoinEndsWithinDeadlinePlusGrace(t *testing.T) {
	clock := newSBClock()
	sb, _ := newTestSandbox(t, `var a = new Array(2e7); while (true) { a.join("abc") }`,
		sbOpts{budget: Budget{Tokens: 1000, Minutes: 1}, clock: clock})
	clock.Advance(59*time.Second + 700*time.Millisecond)
	start := time.Now()
	_, err := sb.Run()
	wantInterrupt(t, err, InterruptTimeout)
	if took := time.Since(start); took > 300*time.Millisecond+AbandonGrace+time.Second {
		t.Fatalf("Run took %v", took)
	}
	waitNoAbandonedRuns(t)
}

func TestSandbox_DeepJSONStringifyRefused(t *testing.T) {
	deep := `var o = {}, c = o; for (var i = 0; i < 200000; i++) { c.a = {}; c = c.a }`
	start := time.Now()
	got := mustRun(t, deep+` try { JSON.stringify(o); return "ran" } catch (e) { return e.name }`, sbOpts{})
	if got != "RangeError" || time.Since(start) > 5*time.Second {
		t.Fatalf("deep stringify = %v after %v; want a quick RangeError", got, time.Since(start))
	}
	ok := mustRun(t, `var o = {}, c = o; for (var i = 0; i < 900; i++) { c.a = {}; c = c.a }
		var cyc = {}; cyc.self = cyc; var cycErr = "";
		try { JSON.stringify(cyc) } catch (e) { cycErr = e.name }
		return JSON.stringify(o).length + "," + cycErr + "," + JSON.stringify({b: [1, 2]}, null, 0)`, sbOpts{})
	if ok != "5402,TypeError,{\"b\":[1,2]}" {
		t.Fatalf("stringify under the cap = %v", ok)
	}
}

func TestSandbox_RepeatCapped(t *testing.T) {
	got := mustRun(t, `var out = ["ab".repeat(3)];
		try { "x".repeat(32 * 1024 * 1024) } catch (e) { out.push(e.name) }
		return out.join(",")`, sbOpts{})
	if got != "ababab,RangeError" {
		t.Fatalf("got %v", got)
	}
}

func TestSandbox_ReturnValueSerialisedUnderInterrupt(t *testing.T) {
	clock := newSBClock()
	sb, _ := newTestSandbox(t, `return { get x() { while (true) {} } }`,
		sbOpts{budget: Budget{Tokens: 1000, Minutes: 1}, clock: clock})
	clock.Advance(59*time.Second + 500*time.Millisecond)
	_, err := runWithin(t, sb, 5*time.Second)
	wantInterrupt(t, err, InterruptTimeout)
}

func TestSandbox_ReturnValueIsJSON(t *testing.T) {
	got := mustRun(t, `return { get x() { return 5 }, toJSON: undefined, list: [1, "a", null], nan: NaN }`, sbOpts{})
	m, ok := got.(map[string]any)
	if !ok || m["x"] != float64(5) || m["nan"] != nil || len(m["list"].([]any)) != 3 {
		t.Fatalf("returned %#v", got)
	}
	for script, wantName := range map[string]string{
		`return { f: function () {} }`:                     ErrNameValidation,
		`return [Symbol("s")]`:                             ErrNameValidation,
		`return { n: 10n }`:                                ErrNameValidation,
		`return function () {}`:                            ErrNameValidation,
		`return "x".repeat(300 * 1024)`:                    ErrNameResultTooLarge,
		`return { get x() { throw new TypeError("no") } }`: "TypeError",
	} {
		_, err := runScript(t, script, sbOpts{})
		var se *ScriptError
		if !errors.As(err, &se) || se.Name != wantName {
			t.Errorf("%s → %v; want a %s", script, err, wantName)
		}
	}
}

func TestSandbox_SDKCallAfterReturnEndsTheRun(t *testing.T) {
	_, err := runScript(t, returnFuncName+`(1); echo(2)`, sbOpts{})
	if !errors.Is(err, ErrSDKContract) {
		t.Fatalf("Run = %v; want ErrSDKContract", err)
	}
}

type structResult struct {
	Name   string `json:"name"`
	hidden int
}

func (structResult) Method() string { return "m" }

func TestSandbox_SDKResultsArePlainJSValues(t *testing.T) {
	mod := funcModule{name: "results", fns: map[string]SDKFunc{
		"jsValue": func(_ *Env, _ goja.FunctionCall, rt *goja.Runtime) (any, error) { return rt.ToValue(1), nil },
		"huge": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			return strings.Repeat("x", MaxSDKResultBytes+1), nil
		},
		"object": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			return structResult{Name: "acme", hidden: 3}, nil
		},
	}}
	got := mustRun(t, `var out = [];
		try { huge() } catch (e) { out.push(e.name) }
		var o = object();
		out.push(o.name, typeof o.Method, typeof o.hidden, Object.getPrototypeOf(o) === Object.prototype);
		return out.join(",")`, sbOpts{modules: []Module{mod}})
	if got != "ResultTooLarge,acme,undefined,undefined,true" {
		t.Fatalf("got %v", got)
	}
	_, err := runScript(t, `try { jsValue() } catch (e) {} return 1`, sbOpts{modules: []Module{mod}})
	if !errors.Is(err, ErrSDKContract) {
		t.Fatalf("a goja.Value result = %v; want ErrSDKContract", err)
	}
}

func TestSandbox_WrapperBreakoutRefused(t *testing.T) {
	for _, script := range []string{
		"})); globalThis.x = 1; " + returnFuncName + "((function () {",
		"})(), (function () {\n",
		"return 1 }).call(null), (function () {", // one statement, two arguments
	} {
		env := &Env{Ctx: context.Background(), Recipe: &Recipe{Script: script}, Journal: NewMemoryJournal(),
			Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, math.MaxInt64, nil)}
		_, err := NewSandbox(env, nil)
		var se *ScriptError
		if !errors.As(err, &se) || se.Message != errWrapperBroken {
			t.Errorf("NewSandbox(%q) = %v; want the wrapper refusal", script, err)
		}
		wantParseError(t, recipeWith(baseFrontmatter, script+"\n"), "closes the function")
	}
	if got := mustRun(t, "const f = function () { return { a: 1 } };\nreturn f().a // }", sbOpts{}); got != float64(1) {
		t.Fatalf("an intact script = %v", got)
	}
}

func TestEnvCall_EncodingFailureReclosesStepAsError(t *testing.T) {
	env := &Env{Journal: NewMemoryJournal()}
	_, err := env.Call("tool", "create_target", nil, func(s *Step) (any, error) {
		s.Finish(db.StepFinish{Status: "proposed", ActionID: 5})
		return strings.Repeat("x", MaxSDKResultBytes+1), nil
	})
	var se *SDKError
	if !errors.As(err, &se) || se.Name != ErrNameResultTooLarge {
		t.Fatalf("Call = %v; want ResultTooLarge", err)
	}
	st := env.Journal.Steps()[0]
	if st.Status != StepError || st.ActionID != 5 || st.FinishedAt == nil {
		t.Fatalf("step = %+v; want error with action 5", st)
	}
	if env.Journal.Err() != nil {
		t.Fatalf("journal Err = %v", env.Journal.Err())
	}
	// A close the function made stays when the result encodes.
	if _, err := env.Call("tool", "x", nil, func(s *Step) (any, error) {
		s.Finish(db.StepFinish{Status: StepDryRun})
		return map[string]string{"status": "dry_run"}, nil
	}); err != nil || env.Journal.Steps()[1].Status != StepDryRun {
		t.Fatalf("held close = %v, %+v", err, env.Journal.Steps()[1])
	}
}

func TestMeter_LiveDailyTotalAcrossRuns(t *testing.T) {
	const capTokens, perCall = 1000, 300
	var spent atomic.Int64
	source := func() (int64, error) { return spent.Load(), nil }
	a := NewMeter(Budget{Tokens: 50000, Minutes: 5}, math.MaxInt64, nil)
	b := NewMeter(Budget{Tokens: 50000, Minutes: 5}, math.MaxInt64, nil)
	a.UseDailyTotal(capTokens, source)
	b.UseDailyTotal(capTokens, source)
	for i := 0; i < 10; i++ {
		m := []*Meter{a, b}[i%2]
		if m.BeforeCall() != nil {
			continue
		}
		m.Debit(perCall, 0) // before the usage is recorded
		spent.Add(perCall)  // the step's Usage writing the run row
	}
	if got := spent.Load(); got > capTokens+perCall {
		t.Fatalf("spent %d; want at most cap + one call (%d)", got, capTokens+perCall)
	}
	if a.Crossed() != InterruptDailyCap || b.Crossed() != InterruptDailyCap {
		t.Fatalf("crossed = %q / %q; want daily_cap on both", a.Crossed(), b.Crossed())
	}
}

func TestMeter_DailyTotalReadErrorRefusesCall(t *testing.T) {
	m := NewMeter(Budget{Tokens: 50000, Minutes: 5}, math.MaxInt64, nil)
	m.UseDailyTotal(1000, func() (int64, error) { return 0, sql.ErrConnDone })
	var se *SDKError
	if err := m.BeforeCall(); !errors.As(err, &se) || se.Name != ErrNameBudget || !strings.Contains(se.Message, "connection") {
		t.Fatalf("BeforeCall = %v; want a refusal naming the read error", err)
	}
	if m.Crossed() != "" {
		t.Fatalf("a read error flagged %q", m.Crossed())
	}
}

func TestJournal_UsesClock(t *testing.T) {
	clock := newSBClock()
	j := NewMemoryJournal().UseClock(clock)
	s := j.Begin("log", "", "x")
	clock.Advance(1500 * time.Millisecond)
	s.OK(nil)
	st := j.Steps()[0]
	if !st.StartedAt.Equal(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)) || st.DurationMS != 1500 {
		t.Fatalf("step = started %v, %d ms", st.StartedAt, st.DurationMS)
	}
	// NewSandbox gives a journal without a clock the meter's.
	adopt := NewMemoryJournal()
	if _, err := NewSandbox(&Env{Ctx: context.Background(), Recipe: &Recipe{Script: "1"}, Journal: adopt,
		Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, math.MaxInt64, clock)}, nil); err != nil {
		t.Fatal(err)
	}
	if got := adopt.Begin("log", "", nil); !adopt.Steps()[0].StartedAt.Equal(clock.Now()) {
		t.Fatalf("adopted clock not used (step %d)", got.ID())
	}
}

func TestJournal_MarkWrapsErrors(t *testing.T) {
	d, run := seedJournalRun(t)
	j := NewJournal(d, run, false)
	s := j.Begin("tool", "x", nil)
	if _, err := d.Exec(`DELETE FROM automation_run_steps WHERE id = ?`, s.ID()); err != nil {
		t.Fatal(err)
	}
	err := s.Mark(StepWaiting, db.StepFinish{ActionID: 1})
	if !errors.Is(err, db.ErrAutomationRunStepNotFound) || !strings.Contains(err.Error(), "marking automation run") {
		t.Fatalf("Mark = %v; want a wrapped not-found error", err)
	}
}
