package automations

import (
	"context"
	"errors"
	"strings"
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
	sb, _ := newTestSandbox(t, `var a = new Array(16e6); while (true) { a.join("") }`,
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

func TestSandbox_ReturnHookIsHiddenAndPostReturnCallsAreScriptErrors(t *testing.T) {
	got := mustRun(t, `return [typeof `+returnHookParam+`, typeof globalThis.`+returnHookParam+`, arguments.length].join(",")`, sbOpts{})
	if got != "undefined,undefined,0" {
		t.Fatalf("hook visibility = %v", got)
	}
	_, err := runScript(t, `return { get x() { echo(1); return 1 } }`, sbOpts{})
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != ErrNameValidation || !strings.Contains(se.Message, "echo") {
		t.Fatalf("Run = %v; want a ValidationError naming echo", err)
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
		"}).call(null), (function () {", // one statement, two hook arguments
		"})()); globalThis.x = 1; " + returnHookParam + "((function () {",
		"})()); }); globalThis.x = 1; (function (" + returnHookParam + ") { " + returnHookParam + "((function () {",
	} {
		env := &Env{Ctx: context.Background(), Recipe: &Recipe{Script: script}, Journal: NewMemoryJournal(),
			Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, nil)}
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
		Meter: NewMeter(Budget{Tokens: 1000, Minutes: 1}, clock)}, nil); err != nil {
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

const deepJS = `function deep(n) { var o = {}, c = o; for (var i = 0; i < n; i++) { c.a = {}; c = c.a } return o }
`

// wantQuickRangeError runs script (which returns e.name or "ran") and wants
// a RangeError within 5 s and no abandoned goroutine.
func wantQuickRangeError(t *testing.T, name, script string) {
	t.Helper()
	start := time.Now()
	got := mustRun(t, deepJS+script, sbOpts{})
	if got != "RangeError" || time.Since(start) > 5*time.Second || AbandonedRuns() != 0 {
		t.Errorf("%s: got %v after %v (abandoned %d); want a quick RangeError", name, got, time.Since(start), AbandonedRuns())
	}
}

func TestSandbox_JSONDepthCannotBeBypassed(t *testing.T) {
	waitNoAbandonedRuns(t)
	wrap := func(body string) string {
		return "try { " + body + "; return 'ran' } catch (e) { return e.name }"
	}
	cases := map[string]string{
		"toJSON":        wrap(`JSON.stringify({ toJSON: function () { return deep(200000) } })`),
		"nested toJSON": wrap(`JSON.stringify({ a: { toJSON: function () { return deep(200000) } } })`),
		"getter changes": wrap(`var n = 0; var x = { get v() { n++; return n === 1 ? {} : deep(200000) } };
			JSON.stringify(x); JSON.stringify(x)`),
		"Set.has override": "Set.prototype.has = function () { return true }; Set.prototype.add = function () { return this };\n" +
			wrap(`JSON.stringify(deep(200000))`),
		"intrinsics overridden": `WeakMap.prototype.get = function () { return 0 }; WeakMap.prototype.set = function () {};
			var FP = Object.getPrototypeOf(function () {});
			FP.call = function () { return 0 }; FP.apply = function () { return 0 }; FP.bind = function () { return 0 };
			Reflect.apply = function () { return 0 }; Math.floor = function () { return 0 }; Array.isArray = function () { return false };
			Object.keys = function () { return [] }; Array.prototype.includes = function () { return true };` + "\n" +
			wrap(`JSON.stringify(deep(200000))`),
		"user replacer":  wrap(`JSON.stringify(deep(200000), function (k, v) { return v })`),
		"array replacer": wrap(`JSON.stringify(deep(200000), ["a"])`),
	}
	for name, script := range cases {
		wantQuickRangeError(t, name, script)
	}
	_, err := runScript(t, deepJS+"return deep(2000)", sbOpts{})
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != "RangeError" {
		t.Errorf("deep return value = %v; want a RangeError", err)
	}
}

func TestSandbox_JSONStringifyStillWorks(t *testing.T) {
	got := mustRun(t, `return [
		JSON.stringify({ a: 1, b: 2, c: { a: 3, d: 4 } }, ["a", "c"]),
		JSON.stringify({ a: 1, b: [1, 2] }, function (k, v) { return k === "a" ? 10 : v }),
		JSON.stringify({ a: [1] }, null, 1),
		JSON.stringify({ d: new Date(0) }),
		String(JSON.stringify(undefined))
	].join("|")`, sbOpts{})
	want := `{"a":1,"c":{"a":3}}|{"a":10,"b":[1,2]}|{` + "\n" + ` "a": [` + "\n" + `  1` + "\n" + ` ]` + "\n" + `}|{"d":"1970-01-01T00:00:00.000Z"}|undefined`
	if got != want {
		t.Fatalf("got %q\nwant %q", got, want)
	}
}

func TestSandbox_RegexTimeoutThrows(t *testing.T) {
	start := time.Now()
	_, err := runScript(t, `return /(a+)+b(?=c)/.test("a".repeat(33))`, sbOpts{}) // deadline 5 min
	var se *ScriptError
	if !errors.As(err, &se) || se.Name != "RangeError" || !strings.Contains(se.Message, "too long") {
		t.Fatalf("Run = %v; want an uncaught RangeError, never false", err)
	}
	if took := time.Since(start); took > RegexpMatchTimeout+2*time.Second {
		t.Fatalf("took %v", took)
	}
	got := mustRun(t, `var out = [];
		try { delete RegExp.prototype.exec } catch (e) { out.push(e.name) }
		try { RegExp.prototype[Symbol.replace] = function () { return "fake" } } catch (e) { out.push(e.name) }
		try { "a".repeat(33).replace(/(a+)+b(?=c)/, "x"); out.push("ran") } catch (e) { out.push(e.name) }
		return out.join(",")`, sbOpts{})
	if got != "TypeError,TypeError,RangeError" {
		t.Fatalf("got %v; want TypeError,TypeError,RangeError", got)
	}
}

func TestSandbox_RegexMethodsStillWork(t *testing.T) {
	got := mustRun(t, `var re = /(\w)(\d)(?=x)/g, s = "a1x b2x c3";
		return [
			/b(?=c)/.test("abc"), JSON.stringify(/(\d+)/.exec("ab12")), JSON.stringify(s.match(re)),
			Array.from(s.matchAll(re), function (m) { return m[0] }).join("+"), s.replace(re, "#"),
			s.search(/c/), "a,b;c".split(/[,;]/).join("|"), "x".replace(/x/, function () { return "y" })
		].join(" ")`, sbOpts{})
	if got != `true ["12","12"] ["a1","b2"] a1+b2 #x #x c3 8 a|b|c y` {
		t.Fatalf("got %q", got)
	}
}

func TestSandbox_AllocationCaps(t *testing.T) {
	refused := []string{
		`"x".repeat(32 * 1024 * 1024)`,
		`Math.floor = function () { return 0 }; String = function () { return "" }; "x".repeat(32 * 1024 * 1024)`,
		`"x".padStart(32 * 1024 * 1024)`,
		`"x".padEnd(32 * 1024 * 1024, "y")`,
		`Array.prototype.join.call({ length: 1e9 }, "")`,
		`new Array(1e9)`,
		`Array(1e9)`,
		`[].constructor(1e9)`,
		`Array.from({ length: 1e9 })`,
		`Array.prototype.fill.call({ length: 1e9 }, 0)`,
		`String.raw({ raw: { length: 1e9 } })`,
	}
	for _, expr := range refused {
		got := mustRun(t, "try { "+expr+"; return 'ran' } catch (e) { return e.name }", sbOpts{})
		if got != "RangeError" {
			t.Errorf("%s → %v; want RangeError", expr, got)
		}
	}
	got := mustRun(t, `return [
		"ab".repeat(3), "7".padStart(3, "0"), [1, 2].join("-"), Array(3).length, new Array(1, 2).length,
		Array.isArray(new Array(2)), [] instanceof Array, Array.from([1, 2]).length, Array.from({ length: 2 }).length,
		JSON.stringify([0, 0, 0].fill(1, 1)), JSON.stringify([0, 0, 0].fill(2, -1)), String.raw`+"`a${1}b`"+`,
		Array.of(4).length, [1, [2]].toString(), Array.name, (function () { class L extends Array {} return new L(2) instanceof L })(),
		[1, 2, 3].map(function (x) { return x * 2 }).join("")
	].join("|")`, sbOpts{})
	if got != "ababab|007|1-2|3|2|true|true|2|2|[0,1,1]|[0,0,2]|a1b|1|1,2|Array|true|246" {
		t.Fatalf("got %q", got)
	}
}

func TestEnv_MeteredModelCallOrder(t *testing.T) {
	d, run := seedJournalRun(t)
	var seq []string
	tokensOnRun := func() int64 {
		r, err := d.GetAutomationRun(run)
		if err != nil {
			t.Fatal(err)
		}
		return r.InputTokens + r.OutputTokens
	}
	meter := NewMeter(Budget{Tokens: 1000, Minutes: 5}, nil)
	env := &Env{Ctx: context.Background(), Journal: NewJournal(d, run, false), Meter: meter}
	step := env.Journal.Begin("llm", "light", "p")
	err := env.MeteredModelCall(step, func(context.Context) (ModelUsage, error) {
		seq = append(seq, "generate")
		return ModelUsage{InputTokens: 600, OutputTokens: 500}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// BeforeCall admits the call, the generator runs, Debit crosses the run
	// budget with this call's 1100, then Usage writes the run row.
	if got := strings.Join(seq, ","); got != "generate" {
		t.Fatalf("order = %s", got)
	}
	if meter.Crossed() != InterruptBudget || tokensOnRun() != 1100 {
		t.Fatalf("crossed %q, run tokens %d; want budget, 1100", meter.Crossed(), tokensOnRun())
	}
	called := false
	if err := env.MeteredModelCall(env.Journal.Begin("llm", "light", "p"), func(context.Context) (ModelUsage, error) {
		called = true
		return ModelUsage{}, nil
	}); err == nil || called {
		t.Fatalf("a call over the cap = %v (generator called %v); want a refusal before the generator", err, called)
	}
}

func TestSandbox_AllocationCapsRound3(t *testing.T) {
	refused := []string{
		`var big = "x".repeat(9 * 1024 * 1024); [big, big].join("")`,
		`var big = "x".repeat(9 * 1024 * 1024); [big, ""].join("y".repeat(9 * 1024 * 1024))`,
		`var big = "x".repeat(9 * 1024 * 1024); big.concat(big)`,
		`var big = "x".repeat(9 * 1024 * 1024); "".concat(big, "a", big)`,
		`"x".repeat(1024).replaceAll("x", "y".repeat(32 * 1024))`,
		`var a = new Array(9 * 1024 * 1024); a.concat(a)`,
		`new ArrayBuffer(32 * 1024 * 1024)`,
		`new Uint8Array(32 * 1024 * 1024)`,
		`new Float64Array(17 * 1024 * 1024)`,
		`var a = []; a.length = 1000001; a.sort()`,
		`new Int32Array(1000001).sort()`,
	}
	for _, expr := range refused {
		got := mustRun(t, "try { "+expr+"; return 'ran' } catch (e) { return e.name }", sbOpts{})
		if got != "RangeError" {
			t.Errorf("%s → %v; want RangeError", expr, got)
		}
	}
	got := mustRun(t, `var calls = 0, obj = { toString: function () { calls++; return "o" } };
		var u8 = new Uint8Array([3, 1, 2]);
		return [
			[1, null, undefined, "a", [2, 3]].join("-"), [obj, obj].join(), calls, "a".concat(1, obj), calls,
			"aXbX".replaceAll("X", "-"), [1].concat([2, [3]], 4).length, new ArrayBuffer(8).byteLength,
			u8.sort().join(""), u8 instanceof Uint8Array, new Uint8Array(4).length, typeof Uint8Array.from,
			[3, 1, 2].sort().join(""), [3, 1, 2].sort(function (a, b) { return b - a }).join("")
		].join("|")`, sbOpts{})
	if got != "1---a-2,3|o,o|2|a1o|3|a-b-|4|8|123|true|4|function|123|321" {
		t.Fatalf("got %q", got)
	}
	threw := mustRun(t, `try { Uint8Array(2); return "ran" } catch (e) { return e.name }`, sbOpts{})
	if threw != "TypeError" {
		t.Fatalf("Uint8Array without new = %v; want TypeError", threw)
	}
}

func TestSandbox_SortWithComparatorStaysInterruptible(t *testing.T) {
	clock := newSBClock()
	sb, _ := newTestSandbox(t, `var a = []; for (var i = 0; i < 1500000; i++) { a.push(i % 7) }
		a.sort(function (x, y) { while (true) {} })`, sbOpts{budget: Budget{Tokens: 1000, Minutes: 1}, clock: clock})
	clock.Advance(59 * time.Second)
	_, err := runWithin(t, sb, 10*time.Second)
	var ri *RunInterrupted
	if !errors.As(err, &ri) || ri.Reason != InterruptTimeout || ri.Abandoned {
		t.Fatalf("Run = %v; want a timeout that did not need abandoning", err)
	}
}

func TestSandbox_ArrayReplacerKeyOrder(t *testing.T) {
	got := mustRun(t, `var n = 0;
		var o = { b: 1, a: 2, c: { b: 3, a: 4, z: 5 }, get skipped() { n++; return 1 } };
		return [
			JSON.stringify(o, ["c", "a", "b", "a"]),
			JSON.stringify(o, [new String("b"), 1, {}, true]),
			JSON.stringify([{ b: 1, a: 2 }], ["a"]),
			JSON.stringify({ 1: "one", __proto__x: 0 }, [1]),
			n
		].join("|")`, sbOpts{})
	if got != `{"c":{"a":4,"b":3},"a":2,"b":1}|{"b":1}|[{"a":2}]|{"1":"one"}|0` {
		t.Fatalf("got %q", got)
	}
}
