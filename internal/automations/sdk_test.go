package automations_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dop251/goja"
	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// sdkCase configures one SDK test run.
type sdkCase struct {
	perms     []string
	outputs   []string
	committed string // committed state JSON
	dryRun    bool
	journal   *automations.Journal
	gen       *automationstest.FakeGenerator
	reg       *automationstest.FakeRegistry
	backends  *automations.Backends // nil = Generator, Registry and a clock
	modules   []automations.Module  // nil = DefaultModules
}

type sdkRun struct {
	env *automations.Env
	gen *automationstest.FakeGenerator
	reg *automationstest.FakeRegistry
	out any
	err error
}

func listSchema() *jsonschema.Schema {
	return &jsonschema.Schema{Type: "object", Properties: map[string]*jsonschema.Schema{
		"limit":   {Type: "integer"},
		"project": {Type: "string"},
		"account": {Type: "string"},
	}}
}

// fakeTools is the registry the SDK tests call.
func fakeTools() *automationstest.FakeRegistry {
	read := func(name string) *tools.Tool {
		return &tools.Tool{Name: name, Access: tools.AccessRead, InputSchema: listSchema()}
	}
	return &automationstest.FakeRegistry{
		Tools: map[string]*tools.Tool{
			"list_jira_issues": read("list_jira_issues"),
			"list_targets":     read("list_targets"),
			"list_emails":      read("list_emails"),
			"get_target":       {Name: "get_target", Access: tools.AccessRead},
			"create_target":    {Name: "create_target", Access: tools.AccessWrite},
		},
		ReadResults: map[string]any{
			"list_targets": []map[string]any{{"id": 7, "title": "Ship it"}},
			"get_target":   map[string]any{"id": 7},
		},
	}
}

func runSDK(t *testing.T, script string, c sdkCase) sdkRun {
	t.Helper()
	if c.gen == nil {
		c.gen = &automationstest.FakeGenerator{Replies: []string{"ok"}}
	}
	if c.reg == nil {
		c.reg = fakeTools()
	}
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	b := automations.Backends{Generator: c.gen, Registry: c.reg, Clock: clock}
	if c.backends != nil {
		b = *c.backends
	}
	if c.modules == nil {
		c.modules = automations.DefaultModules(b)
	}
	if c.journal == nil {
		c.journal = automations.NewMemoryJournal()
	}
	m, err := automations.ParseManifest(c.perms, c.outputs, automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatalf("ParseManifest: %v", err)
	}
	env := &automations.Env{
		Ctx:        context.Background(),
		Run:        &db.AutomationRun{ID: 42, AutomationID: 3},
		Automation: &db.Automation{ID: 3, Slug: "acme"},
		Recipe:     &automations.Recipe{Script: script, ScriptLine: 10},
		Manifest:   m,
		DryRun:     c.dryRun,
		Journal:    c.journal,
		Meter:      automations.NewMeter(automations.Budget{Tokens: 50000, Minutes: 5}, math.MaxInt64, clock),
		Buffer:     automations.NewCommitBuffer(json.RawMessage(c.committed)),
	}
	sb, err := automations.NewSandbox(env, c.modules)
	if err != nil {
		t.Fatalf("NewSandbox: %v", err)
	}
	out, err := sb.Run()
	return sdkRun{env: env, gen: c.gen, reg: c.reg, out: out, err: err}
}

// mustReturn runs script and fails the test unless it returns want.
func mustReturn(t *testing.T, script string, c sdkCase, want any) sdkRun {
	t.Helper()
	r := runSDK(t, script, c)
	if r.err != nil {
		t.Fatalf("Run: %v", r.err)
	}
	if fmt.Sprint(r.out) != fmt.Sprint(want) {
		t.Fatalf("script returned %#v; want %#v", r.out, want)
	}
	return r
}

func stepStatuses(steps []db.AutomationRunStep) []string {
	out := make([]string, len(steps))
	for i, s := range steps {
		out[i] = s.Kind + ":" + s.Status
	}
	return out
}

func TestLLM_DefaultLightTierAndSourceTag(t *testing.T) {
	r := mustReturn(t, `llm("one"); llm("two", {tier: "strong"}); return "done"`,
		sdkCase{perms: []string{"llm:strong"}}, "done")
	calls := r.gen.Snapshot()
	if len(calls) != 2 || calls[0].Source != automations.SourceLLMLight || calls[1].Source != automations.SourceLLMStrong {
		t.Fatalf("generator calls = %+v; want sources %q then %q", calls, automations.SourceLLMLight, automations.SourceLLMStrong)
	}
	if digest.TierForSource(calls[0].Source) != digest.TierLight || digest.TierForSource(calls[1].Source) != digest.TierStrong {
		t.Fatalf("tiers: %q → %s, %q → %s", calls[0].Source, digest.TierForSource(calls[0].Source),
			calls[1].Source, digest.TierForSource(calls[1].Source))
	}
	if !strings.HasPrefix(calls[0].UserMessage, "one") {
		t.Fatalf("user message = %q; want the prompt first", calls[0].UserMessage)
	}
}

func TestLLM_StrongNeedsStrongPermission(t *testing.T) {
	r := mustReturn(t, `try { llm("x", {tier: "strong"}); return "called" } catch (e) { return e.name + "|" + e.needed }`,
		sdkCase{perms: []string{"llm:light"}}, "PermissionDenied|llm:strong")
	if n := r.gen.CallCount(); n != 0 {
		t.Fatalf("generator called %d times; want 0", n)
	}
}

func TestLLM_SchemaRetryOnceThenValidationError(t *testing.T) {
	const script = `try {
		var r = llm("give", {schema: {type: "object", properties: {a: {type: "integer"}}, required: ["a"]}});
		return "a=" + r.a
	} catch (e) { return e.name }`
	cases := []struct {
		name    string
		replies []string
		want    string
	}{
		{"two bad replies", []string{"nope", "still no"}, "ValidationError"},
		{"second reply valid", []string{"x", `{"a":1}`}, "a=1"},
		{"fenced reply valid", []string{"```json\n{\"a\":2}\n```"}, "a=2"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gen := &automationstest.FakeGenerator{Replies: tc.replies}
			r := mustReturn(t, script, sdkCase{perms: []string{"llm:light"}, gen: gen}, tc.want)
			calls := r.gen.Snapshot()
			if len(calls) != len(tc.replies) {
				t.Fatalf("generator called %d times; want %d", len(calls), len(tc.replies))
			}
			if len(calls) == 2 && !strings.Contains(calls[1].UserMessage, "not accepted") {
				t.Fatalf("retry message = %q; want the validation error fed back", calls[1].UserMessage)
			}
		})
	}
}

func TestLLM_InputTooLarge(t *testing.T) {
	// The limit covers prompt + input + schema together (stricter than §5).
	cases := map[string]struct{ call, wantMsg string }{
		"input":            {`llm("sum", {input: "x".repeat(201 * 1024)})`, "input too large"},
		"prompt":           {`llm("x".repeat(201 * 1024))`, "input too large"},
		"prompt and input": {`llm("x".repeat(100 * 1024), {input: "y".repeat(101 * 1024)})`, "input too large"},
		"options object":   {`llm("p", {schema: {description: "x".repeat(300 * 1024)}})`, "options object is larger than 262144 bytes"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			r := runSDK(t, `try { `+tc.call+`; return "called" } catch (e) {
				return e.name + "|" + (e.message.indexOf(`+strconv.Quote(tc.wantMsg)+`) >= 0) + "|" + e.message.slice(0, 200) }`,
				sdkCase{perms: []string{"llm:light"}})
			if r.err != nil {
				t.Fatalf("Run: %v", r.err)
			}
			if got := fmt.Sprint(r.out); !strings.HasPrefix(got, "ValidationError|true|") {
				t.Fatalf("script returned %q; want a ValidationError naming %q", got, tc.wantMsg)
			}
			if n := r.gen.CallCount(); n != 0 {
				t.Fatalf("generator called %d times; want 0", n)
			}
			if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepError {
				t.Fatalf("steps = %v; want one error step", stepStatuses(steps))
			}
		})
	}
}

func TestLLM_FailedCallDebitsOnlyReportedUsage(t *testing.T) {
	cases := []struct {
		name  string
		usage []digest.Usage
		want  int64
	}{
		{"no usage", nil, 0},
		{"reported usage", []digest.Usage{{InputTokens: 10, OutputTokens: 5}}, 15},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gen := &automationstest.FakeGenerator{Errors: []error{errors.New("provider down")}, Usage: tc.usage}
			r := mustReturn(t, `try { llm("x"); return "called" } catch (e) { return e.name + "|" + e.message }`,
				sdkCase{perms: []string{"llm:light"}, gen: gen}, "ToolError|the model call failed: provider down")
			tot := r.env.Journal.Totals()
			if got := tot.InputTokens + tot.OutputTokens; got != tc.want || tot.Estimated {
				t.Fatalf("debited %d (estimated %v); want %d, not estimated", got, tot.Estimated, tc.want)
			}
			if rem := r.env.Meter.Remaining().Tokens; rem != 50000-int(tc.want) {
				t.Fatalf("meter remaining = %d; want %d", rem, 50000-int(tc.want))
			}
		})
	}
}

func TestLLM_ReportedCostRecorded(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"a", "b"},
		Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5, CostUSD: 0.25}, {InputTokens: 10, OutputTokens: 5}}}
	r := mustReturn(t, `llm("x"); llm("y"); return 1`, sdkCase{perms: []string{"llm:light"}, gen: gen}, 1)
	steps := r.env.Journal.Steps()
	if steps[0].ReportedCostUSD == nil || *steps[0].ReportedCostUSD != 0.25 || steps[1].ReportedCostUSD != nil {
		t.Fatalf("step costs = %v, %v; want 0.25 and none", steps[0].ReportedCostUSD, steps[1].ReportedCostUSD)
	}
	if c := r.env.Journal.Totals().ReportedCostUSD; c == nil || *c != 0.25 {
		t.Fatalf("run cost = %v; want 0.25", c)
	}
}

func TestLLM_SchemaRetryDebitsBothCalls(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"x", `{"a":1}`},
		Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}}}
	r := mustReturn(t, `return llm("give", {schema: {type: "object"}}).a`, sdkCase{perms: []string{"llm:light"}, gen: gen}, 1)
	if tot := r.env.Journal.Totals(); tot.InputTokens+tot.OutputTokens != 30 {
		t.Fatalf("debited %d; want 30 (both calls)", tot.InputTokens+tot.OutputTokens)
	}
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].InputTokens+steps[0].OutputTokens != 30 {
		t.Fatalf("steps = %+v; want one llm step carrying both calls' tokens", steps)
	}
}

func TestLLM_SchemaNullReplyIsNull(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"null"}}
	mustReturn(t, `return String(llm("nothing", {schema: {type: "null"}}) === null)`,
		sdkCase{perms: []string{"llm:light"}, gen: gen}, "true")
}

// openRunDB opens a test DB with a claimed run of a seeded automation.
func openRunDB(t *testing.T) (*db.DB, *db.AutomationRun) {
	t.Helper()
	d := db.OpenTestDB(t)
	now := time.Now().UTC()
	a := automationstest.SeedAutomation(t, d, sdkRecipe, automationstest.SeedOptions{Now: now})
	id, _, err := d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: now})
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if ok, err := d.ClaimAutomationRun(id, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, now); err != nil || !ok {
		t.Fatalf("claim: ok=%v err=%v", ok, err)
	}
	run, err := d.GetAutomationRun(id)
	if err != nil {
		t.Fatalf("get run: %v", err)
	}
	return d, run
}

const sdkRecipe = "---\nname: SDK test\ntrigger:\n  manual: true\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n" +
	"Exercises the SDK.\n\n```js\nllm(\"x\")\n```\n"

func TestLLM_DebitsInputPlusOutputTokens(t *testing.T) {
	cases := []struct {
		name          string
		usage         []digest.Usage
		wantEstimated bool
	}{
		{"reported usage", []digest.Usage{{InputTokens: 100, OutputTokens: 50}}, false},
		{"no usage", nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, run := openRunDB(t)
			gen := &automationstest.FakeGenerator{Replies: []string{"a reply of some length"}, Usage: tc.usage}
			r := mustReturn(t, `return llm("count my tokens", {input: {n: 1}})`,
				sdkCase{perms: []string{"llm:light"}, gen: gen, journal: automations.NewJournal(d, run.ID, false)},
				"a reply of some length")
			got, err := d.GetAutomationRun(run.ID)
			if err != nil {
				t.Fatal(err)
			}
			want := int64(150)
			if tc.wantEstimated {
				c := r.gen.Snapshot()[0]
				want = int64(math.Ceil(float64(len(c.SystemPrompt)+len(c.UserMessage)+len("a reply of some length")) / 4))
			}
			if total := got.InputTokens + got.OutputTokens; total != want || got.TokensEstimated != tc.wantEstimated {
				t.Fatalf("run tokens = %d (estimated %v); want %d (estimated %v)", total, got.TokensEstimated, want, tc.wantEstimated)
			}
			if rem := r.env.Meter.Remaining().Tokens; rem != 50000-int(want) {
				t.Fatalf("meter remaining = %d; want %d", rem, 50000-int(want))
			}
		})
	}
}

func TestAuto01_DeniedCallThrowsAndWritesDeniedStep(t *testing.T) {
	r := mustReturn(t, `try { tool("list_jira_issues", {project: "OPS"}); return "called" } catch (e) {
		return e.name + "|" + e.needed }`,
		sdkCase{perms: []string{"jira:read@PAY"}}, "PermissionDenied|jira:read@OPS")
	if reads := r.reg.ReadCalls(); len(reads) != 0 {
		t.Fatalf("registry reads = %+v; want none", reads)
	}
	steps := r.env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != automations.StepDenied || steps[0].Permission != "jira:read@OPS" {
		t.Fatalf("steps = %+v; want one denied step needing jira:read@OPS", steps)
	}
}

func TestTool_DeniedLookupKeepsCauseOnStep(t *testing.T) {
	// list_emails resolves its account through the DB; Backends.DB is nil.
	r := mustReturn(t, `try { tool("list_emails", {account: "work"}); return "called" } catch (e) {
		return e.name + "|" + e.needed + "|" + (e.message.indexOf("database") >= 0) }`,
		sdkCase{perms: []string{"gmail:read@work"}}, "PermissionDenied|gmail:read@*|false")
	steps := r.env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != automations.StepDenied || !strings.Contains(steps[0].Error, "database") {
		t.Fatalf("steps = %+v; want a denied step whose error keeps the lookup cause", steps)
	}
}

func TestTool_ReadThroughCallReadWithAutomationBinding(t *testing.T) {
	r := mustReturn(t, `var ts = tool("list_targets", {}); return ts[0].title`,
		sdkCase{perms: []string{"targets:read"}}, "Ship it")
	reads := r.reg.ReadCalls()
	if len(reads) != 1 {
		t.Fatalf("reads = %+v; want one", reads)
	}
	b := reads[0].Binding
	if b.Surface != tools.AutomationSurface || b.ContextType != tools.AutomationContextType || b.ContextID != "42" {
		t.Fatalf("binding = %+v; want surface %q, context %q/42", b, tools.AutomationSurface, tools.AutomationContextType)
	}
	steps := r.env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != automations.StepOK || steps[0].Permission != "targets:read" || steps[0].Name != "list_targets" {
		t.Fatalf("steps = %+v; want one ok list_targets step admitted by targets:read", steps)
	}
}

func TestTool_LimitInjectedAndClamped(t *testing.T) {
	cases := []struct{ args, want string }{
		{`{}`, "50"},
		{`{limit: 1000}`, "200"},
		{`{limit: 20}`, "20"},
	}
	for _, tc := range cases {
		t.Run(tc.args, func(t *testing.T) {
			r := mustReturn(t, `tool("list_targets", `+tc.args+`); return 1`, sdkCase{perms: []string{"targets:read"}}, 1)
			var got map[string]json.RawMessage
			if err := json.Unmarshal(r.reg.ReadCalls()[0].Args, &got); err != nil {
				t.Fatal(err)
			}
			if string(got["limit"]) != tc.want {
				t.Fatalf("limit sent = %s; want %s", got["limit"], tc.want)
			}
		})
	}
}

func TestTool_NullResultIsNull(t *testing.T) {
	reg := fakeTools()
	reg.ReadResults["list_targets"] = nil
	mustReturn(t, `return String(tool("list_targets") === null)`, sdkCase{perms: []string{"targets:read"}, reg: reg}, "true")
}

func TestTool_WriteNotAvailableInP1(t *testing.T) {
	r := mustReturn(t, `try { tool("create_target", {title: "x"}); return "called" } catch (e) { return e.name }`,
		sdkCase{perms: []string{"tool:create_target"}}, "NotAvailable")
	if p := r.reg.ProposedCalls(); len(p) != 0 {
		t.Fatalf("proposals = %+v; want none", p)
	}
}

func TestTool_BadCallsAreValidationErrors(t *testing.T) {
	for _, call := range []string{`tool(1)`, `tool("list_targets", [1])`, `tool("no_such_tool", {})`} {
		t.Run(call, func(t *testing.T) {
			r := mustReturn(t, `try { `+call+`; return "called" } catch (e) { return e.name }`,
				sdkCase{perms: []string{"targets:read"}}, "ValidationError")
			if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepError {
				t.Fatalf("steps = %v; want one error step", stepStatuses(steps))
			}
		})
	}
}

func TestTool_RegistryErrorsMapToSDKNames(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{&tools.ValidationError{Msg: "bad project"}, "ValidationError|bad project"},
		{errors.New("disk on fire"), "ToolError|list_targets: disk on fire"},
	}
	for _, tc := range cases {
		t.Run(tc.want, func(t *testing.T) {
			reg := fakeTools()
			reg.ReadErrors = map[string]error{"list_targets": tc.err}
			mustReturn(t, `try { tool("list_targets"); return "called" } catch (e) { return e.name + "|" + e.message }`,
				sdkCase{perms: []string{"targets:read"}, reg: reg}, tc.want)
		})
	}
}

func TestState_ReadsCommittedPlusOwnSets(t *testing.T) {
	r := mustReturn(t, `state.set("b", 2); state.set("n", null);
		return [state.get("a"), state.get("b"), state.get("zz") === undefined, state.get("n") === null,
			JSON.stringify(state.all())].join("|")`,
		sdkCase{committed: `{"a":1}`}, `1|2|true|true|{"a":1,"b":2,"n":null}`)
	c := r.env.Buffer.Commit()
	if string(c.StateJSON) != `{"a":1,"b":2,"n":null}` {
		t.Fatalf("committed state = %s", c.StateJSON)
	}
}

func TestState_RejectsUnserialisableValues(t *testing.T) {
	values := map[string]string{
		"function":        `function () {}`,
		"undefined":       `undefined`,
		"cyclic":          `(function () { var o = {}; o.self = o; return o })()`,
		"NaN":             `NaN`,
		"Infinity":        `Infinity`,
		"BigInt":          `10n`,
		"nested function": `{f: function () {}}`,
		"nested NaN":      `[1, NaN]`,
		"symbol":          `Symbol("s")`,
	}
	for name, expr := range values {
		t.Run(name, func(t *testing.T) {
			r := mustReturn(t, `try { state.set("k", `+expr+`); return "set" } catch (e) { return e.name }`,
				sdkCase{}, "ValidationError")
			if c := r.env.Buffer.Commit(); c.StateJSON != nil {
				t.Fatalf("state buffered %s; want nothing", c.StateJSON)
			}
			if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepError {
				t.Fatalf("steps = %v; want one error step", stepStatuses(steps))
			}
		})
	}
}

func TestState_OversizedKeyIsValidationError(t *testing.T) {
	mustReturn(t, `try { state.set("k".repeat(300 * 1024), 1); return "set" } catch (e) { return e.name }`,
		sdkCase{}, "ValidationError")
}

func TestState_TooLargeValueIsStateTooLarge(t *testing.T) {
	for _, n := range []int{65 * 1024, 300 * 1024} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			mustReturn(t, fmt.Sprintf(`try { state.set("k", "x".repeat(%d)); return "set" } catch (e) { return e.name }`, n),
				sdkCase{}, "StateTooLarge")
		})
	}
}

func TestState_ValueConversionFollowsJSON(t *testing.T) {
	mustReturn(t, `state.set("k", {d: new Date(0), u: undefined, a: [undefined, new Number(2), new String("s"), true]});
		return JSON.stringify(state.get("k"))`,
		sdkCase{}, `{"a":[null,2,"s",true],"d":"1970-01-01T00:00:00.000Z"}`)
}

func TestOutput_GateAndBodyLimit(t *testing.T) {
	const call = `try { output.inbox({title: "t", body: BODY}); return "ok" } catch (e) { return e.name }`
	cases := []struct {
		name, body string
		outputs    []string
		want       string
		buffered   int
	}{
		{"no outputs entry", `"b"`, nil, "PermissionDenied", 0},
		{"65 KiB body", `"x".repeat(65 * 1024)`, []string{"inbox"}, "ResultTooLarge", 0},
		{"300 KiB body", `"x".repeat(300 * 1024)`, []string{"inbox"}, "ResultTooLarge", 0},
		{"allowed", `"b"`, []string{"inbox"}, "ok", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := mustReturn(t, strings.Replace(call, "BODY", tc.body, 1), sdkCase{outputs: tc.outputs}, tc.want)
			if got := len(r.env.Buffer.Outputs()); got != tc.buffered {
				t.Fatalf("buffered outputs = %d; want %d", got, tc.buffered)
			}
		})
	}
}

func TestOutput_FieldsAreValidated(t *testing.T) {
	for _, arg := range []string{`{body: "b"}`, `{title: "t", body: 1}`, `{title: "t", body: "b", priority: "urgent"}`,
		`{title: "t", body: "b", extra: 1}`, `"text"`, `{title: "t".repeat(201), body: "b"}`} {
		t.Run(arg, func(t *testing.T) {
			mustReturn(t, `try { output.inbox(`+arg+`); return "ok" } catch (e) { return e.name }`,
				sdkCase{outputs: []string{"inbox"}}, "ValidationError")
		})
	}
	mustReturn(t, `try { output.report({title: "t", body: "b", priority: "high"}); return "ok" } catch (e) { return e.name }`,
		sdkCase{outputs: []string{"report"}}, "ValidationError")
	mustReturn(t, `output.inbox({title: "é".repeat(200), body: "b"}); return "ok"`, sdkCase{outputs: []string{"inbox"}}, "ok")
}

func TestOutput_OversizedArgumentNamesBodyLimit(t *testing.T) {
	mustReturn(t, `try { output.inbox({title: "t", body: "x".repeat(300 * 1024)}) } catch (e) {
		return e.name + "|" + (e.message.indexOf("at most 65536 bytes") >= 0) }`,
		sdkCase{outputs: []string{"inbox"}}, "ResultTooLarge|true")
}

func TestOutput_BufferedRows(t *testing.T) {
	r := mustReturn(t, `output.inbox({title: "A", body: "a", priority: "high"}); output.report({title: "R", body: "r"}); return 1`,
		sdkCase{outputs: []string{"inbox", "report"}}, 1)
	got := r.env.Buffer.Outputs()
	want := []db.AutomationOutput{
		{AutomationID: 3, RunID: 42, Kind: "inbox", Title: "A", Body: "a", Priority: "high"},
		{AutomationID: 3, RunID: 42, Kind: "report", Title: "R", Body: "r"},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("outputs = %+v; want %+v", got, want)
	}
}

func TestOutput_DryRunWritesAreDryRunSteps(t *testing.T) {
	r := mustReturn(t, `var a = output.inbox({title: "t", body: "b"}); var b = state.set("k", 1);
		llm("x"); return [a.status, b.status, state.get("k")].join("|")`,
		sdkCase{perms: []string{"llm:light"}, outputs: []string{"inbox"}, dryRun: true}, "dry_run|dry_run|1")
	want := []string{"output:dry_run", "state:dry_run", "llm:ok", "state:ok"}
	if got := stepStatuses(r.env.Journal.Steps()); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("steps = %v; want %v", got, want)
	}
	if r.gen.CallCount() != 1 {
		t.Fatalf("llm did not run for real in a dry run")
	}
}

func TestLog_Capped(t *testing.T) {
	r := mustReturn(t, `for (var i = 0; i < 200; i++) { log("line", i, {i: i}) }
		var name = "none"; try { log("one too many") } catch (e) { name = e.name }
		for (var j = 0; j < 50; j++) { try { log("more") } catch (e) {} }
		return name`, sdkCase{}, "ValidationError")
	steps := r.env.Journal.Steps()
	if len(steps) != automations.MaxLogCalls+1 || steps[automations.MaxLogCalls].Status != automations.StepError {
		t.Fatalf("got %d log steps (last %v); want %d with the last one an error", len(steps),
			stepStatuses(steps[len(steps)-1:]), automations.MaxLogCalls+1)
	}
	if steps[3].ArgsJSON != `line 3 {"i":3}` {
		t.Fatalf("log message = %q", steps[3].ArgsJSON)
	}
}

func TestLog_CapHoldsAgainstNestedGetterLogs(t *testing.T) {
	r := mustReturn(t, `var o = { get x() { for (var k = 0; k < 5; k++) { try { log("inner") } catch (e) {} } return 1 } };
		for (var i = 0; i < 300; i++) { try { log(o) } catch (e) {} }
		return 1`, sdkCase{}, 1)
	ok, total := 0, 0
	for _, s := range r.env.Journal.Steps() {
		if s.Kind == automations.StepKindLog {
			total++
			if s.Status == automations.StepOK {
				ok++
			}
		}
	}
	if ok != automations.MaxLogCalls || total != automations.MaxLogCalls+1 {
		t.Fatalf("log steps: %d ok of %d; want %d ok and one cap error", ok, total, automations.MaxLogCalls)
	}
}

func TestLog_MessageClippedAndUnloggableValuesShown(t *testing.T) {
	r := mustReturn(t, `log("x".repeat(10000)); log(undefined, NaN, function f() {}); return 1`, sdkCase{}, 1)
	steps := r.env.Journal.Steps()
	if len(steps[0].ArgsJSON) != automations.MaxLogBytes {
		t.Fatalf("clipped message is %d bytes; want %d", len(steps[0].ArgsJSON), automations.MaxLogBytes)
	}
	if !strings.HasPrefix(steps[1].ArgsJSON, "undefined NaN function f") {
		t.Fatalf("message = %q", steps[1].ArgsJSON)
	}
}

func TestOutputMod_RegisterOutputKind(t *testing.T) {
	out := automations.OutputModule()
	out.RegisterOutputKind("briefing", func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
		return env.Call("output", "briefing", nil, func(*automations.Step) (any, error) { return "briefed", nil })
	})
	mustReturn(t, `return [output.briefing(), typeof output.email, typeof output.inbox].join("|")`,
		sdkCase{modules: []automations.Module{out}}, "briefed|undefined|function")
}

func TestBackends_NilShellAndWorkbenchAllowed(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"hi"}}
	b := automations.Backends{Generator: gen, Registry: fakeTools(), Clock: automations.RealClock{}}
	mustReturn(t, `log(llm("x")); tool("list_targets"); state.set("k", 1); output.report({title: "t", body: "b"}); return "ran"`,
		sdkCase{perms: []string{"llm:light", "targets:read"}, outputs: []string{"report"}, backends: &b}, "ran")
}

func TestBackends_NilGeneratorAndRegistryAreNotAvailable(t *testing.T) {
	b := automations.Backends{}
	mustReturn(t, `var out = [];
		try { llm("x") } catch (e) { out.push(e.name) }
		try { tool("list_targets") } catch (e) { out.push(e.name) }
		return out.join("|")`,
		sdkCase{perms: []string{"llm:light", "targets:read"}, backends: &b}, "NotAvailable|NotAvailable")
}

func TestAuto11_EveryCallHasOneStep(t *testing.T) {
	r := mustReturn(t, `llm("x"); tool("get_target", {id: 7});
		try { tool("list_jira_issues", {project: "OPS"}) } catch (e) {}
		state.set("k", 1); output.inbox({title: "t", body: "b"}); log("done"); return 1`,
		sdkCase{perms: []string{"llm:light", "targets:read"}, outputs: []string{"inbox"}}, 1)
	want := []string{"llm:ok", "tool:ok", "tool:denied", "state:ok", "output:ok", "log:ok"}
	if got := stepStatuses(r.env.Journal.Steps()); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("steps = %v; want %v", got, want)
	}
}
