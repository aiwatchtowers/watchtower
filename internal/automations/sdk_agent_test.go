package automations_test

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/dop251/goja"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// agentCase is an SDK case whose backends carry a FakeAgent, a database for
// the actions lookup and gen for llm() calls (nil = a reply without usage).
func agentCase(t *testing.T, a *automationstest.FakeAgent, gen *automationstest.FakeGenerator, perms ...string) sdkCase {
	t.Helper()
	if gen == nil {
		gen = &automationstest.FakeGenerator{Replies: []string{"ok"}}
	}
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	b := automations.Backends{DB: db.OpenTestDB(t), Generator: gen, Registry: fakeTools(), Clock: clock}
	if a != nil {
		b.Agent = a
	}
	return sdkCase{perms: perms, backends: &b, gen: gen}
}

func TestAgent_PermissionNeedsAgentRunAndLLMTier(t *testing.T) {
	a := &automationstest.FakeAgent{}
	r := mustReturn(t, `try { agent("triage", {tier: "strong"}); return "ran" } catch (e) { return e.name + "|" + e.needed }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "PermissionDenied|llm:strong")
	steps := r.env.Journal.Steps()
	require.Len(t, steps, 1)
	assert.Equal(t, automations.StepDenied, steps[0].Status)
	assert.Equal(t, "agent", steps[0].Kind)

	mustReturn(t, `try { agent("triage"); return "ran" } catch (e) { return e.name + "|" + e.needed }`,
		agentCase(t, a, nil, "llm:strong"), "PermissionDenied|agent:run")
	assert.Empty(t, a.Requests(), "a denied agent() never reaches the runner")
}

func TestAgent_WaitOptionRefused(t *testing.T) {
	a := &automationstest.FakeAgent{}
	mustReturn(t, `try { agent("triage", {wait: true}); return "ran" } catch (e) { return e.name + "|" + e.message }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "ValidationError|wait is not available inside agent()")
	assert.Empty(t, a.Requests())
}

func TestAgent_BudgetCarvedFromRun(t *testing.T) {
	spend := &automationstest.FakeGenerator{Replies: []string{"ok"}, Usage: []digest.Usage{{InputTokens: 20000}}}
	a := &automationstest.FakeAgent{Result: automations.AgentResult{Text: "done", InputTokens: 10, OutputTokens: 5}}
	r := mustReturn(t, `llm("spend"); agent("one", {budget: {tokens: 100000, minutes: 100}}); agent("two"); return "ok"`,
		agentCase(t, a, spend, "agent:run", "llm:light"), "ok")
	reqs := a.Requests()
	require.Len(t, reqs, 2)
	assert.Equal(t, 30000, reqs[0].Budget.Tokens, "a larger request is clamped to the run's remainder")
	assert.Equal(t, 5, reqs[0].Budget.Minutes, "minutes are clamped to the run's remainder")
	assert.Equal(t, r.env.Meter.Deadline(), reqs[0].Deadline, "the deadline is the run's")
	assert.Equal(t, 29985, reqs[1].Budget.Tokens, "omitted = the run's remainder after the first agent's 15 tokens")
	steps := r.env.Journal.Steps()
	require.Len(t, steps, 3)
	var args struct {
		Budget automations.Budget `json:"budget"`
	}
	require.NoError(t, json.Unmarshal([]byte(steps[1].ArgsJSON), &args))
	assert.Equal(t, automations.Budget{Tokens: 30000, Minutes: 5}, args.Budget, "the step records the clamped budget")

	// A smaller request is kept, and its minutes set the deadline.
	a = &automationstest.FakeAgent{}
	r = mustReturn(t, `agent("x", {budget: {tokens: 1000, minutes: 2}}); return "ok"`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "ok")
	reqs = a.Requests()
	require.Len(t, reqs, 1)
	assert.Equal(t, automations.Budget{Tokens: 1000, Minutes: 2}, reqs[0].Budget)
	assert.Equal(t, time.Date(2026, 10, 14, 9, 2, 0, 0, time.UTC), reqs[0].Deadline)

	for _, bad := range []string{`{budget: {tokens: 0}}`, `{budget: {minutes: -1}}`, `{budget: 5}`, `{tier: "max"}`, `{tools: "x"}`, `{nope: 1}`} {
		mustReturn(t, `try { agent("x", `+bad+`); return "ran" } catch (e) { return e.name }`,
			agentCase(t, a, nil, "agent:run", "llm:light"), "ValidationError")
	}
	assert.Len(t, a.Requests(), 1)
}

// drainModule defines drain(): the run's whole token budget is debited.
func drainModule() automations.Module {
	return exModule{name: "drain", fns: map[string]automations.SDKFunc{
		"drain": func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			env.Meter.Debit(int64(env.Meter.Remaining().Tokens), 0)
			return nil, nil
		},
	}}
}

// With no tokens left the runner is never called: the run is interrupted on
// its budget (as an llm() call over budget is).
func TestAgent_BudgetSpentNeverReachesRunner(t *testing.T) {
	a := &automationstest.FakeAgent{}
	c := agentCase(t, a, nil, "agent:run", "llm:light")
	c.modules = append(automations.DefaultModules(*c.backends), drainModule())
	r := runSDK(t, `try { drain() } catch (e) {} try { agent("x") } catch (e) {} return "ran"`, c)
	require.Error(t, r.err)
	assert.Equal(t, automations.InterruptBudget, r.env.Meter.Crossed())
	assert.Empty(t, a.Requests())
}

// The hooks are the meter: each model call is checked and debited on the
// run and on the agent()'s own carve; a spent carve stops the loop with a
// catchable BudgetExceeded while the run goes on.
func TestAgent_HooksMeterLocalAndRunBudget(t *testing.T) {
	a := &automationstest.FakeAgent{ModelCalls: [][2]int{{4000, 2000}, {10, 10}}}
	r := mustReturn(t, `try { agent("x", {budget: {tokens: 5000}}); return "ran" } catch (e) { return e.name + "|" + llm("after") }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "BudgetExceeded|ok")
	assert.Equal(t, 1, a.AfterCalls(), "the second model call is refused before it runs")
	steps := r.env.Journal.Steps()
	require.Len(t, steps, 2)
	assert.Equal(t, automations.StepError, steps[0].Status)
	assert.Equal(t, int64(4000), steps[0].InputTokens, "the debited tokens are on the agent step")
	assert.Equal(t, int64(2000), steps[0].OutputTokens)
	assert.Equal(t, 50000-6000-stepTokens(steps[1]), r.env.Meter.Remaining().Tokens, "the agent's 6000 and the llm()'s own")
	assert.Empty(t, r.env.Meter.Crossed(), "the run's budget was not crossed")
}

func stepTokens(s db.AutomationRunStep) int { return int(s.InputTokens + s.OutputTokens) }

// A runner's usage the hooks did not report (a CLI child) is debited once
// after the call, estimated flag and cost included.
func TestAgent_ResultUsageDebitedOnce(t *testing.T) {
	cost := 0.25
	a := &automationstest.FakeAgent{RunnerName: "claude",
		Result: automations.AgentResult{Text: "done", InputTokens: 300, OutputTokens: 100, Estimated: true, ReportedCostUSD: &cost}}
	r := mustReturn(t, `return agent("x").text`, agentCase(t, a, nil, "agent:run", "llm:light"), "done")
	steps := r.env.Journal.Steps()
	require.Len(t, steps, 1)
	assert.Equal(t, "claude", steps[0].Name)
	assert.Equal(t, int64(300), steps[0].InputTokens)
	assert.Equal(t, int64(100), steps[0].OutputTokens)
	assert.True(t, steps[0].TokensEstimated)
	assert.Equal(t, 50000-400, r.env.Meter.Remaining().Tokens)

	// Runtime B reports through the hooks and returns the same totals: no
	// second debit.
	a = &automationstest.FakeAgent{ModelCalls: [][2]int{{30, 20}}, Result: automations.AgentResult{Text: "t", InputTokens: 30, OutputTokens: 20}}
	r = mustReturn(t, `return agent("x").text`, agentCase(t, a, nil, "agent:run", "llm:light"), "t")
	assert.Equal(t, 50000-50, r.env.Meter.Remaining().Tokens)
}

// The request carries the effective tool set, the run's binding marked as an
// agent's, the tier and the dry-run flag; the result's actions are the run's
// agent_actions rows the call added; the step journals instruction, tools,
// budget and tier.
func TestAgent_RequestStepAndActions(t *testing.T) {
	a := &automationstest.FakeAgent{Result: automations.AgentResult{Text: "filed one"}}
	c := agentCase(t, a, nil, "agent:run", "llm:strong", "tool:list_targets", "tool:create_target")
	d := c.backends.DB
	insert := func(ctxID string) int64 {
		id, err := d.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: "{}", Reason: "r",
			Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType, ContextID: ctxID})
		require.NoError(t, err)
		return id
	}
	insert("42") // before the call: not this call's
	var made int64
	a.OnRun = func(automations.AgentRequest) {
		insert("43") // another run's
		made = insert("42")
	}
	r := runSDK(t, `const res = agent("file the open items", {tools: ["create_target", "list_targets", "list_emails"], tier: "strong"});
		return res.text + "|" + JSON.stringify(res.actions)`, c)
	require.NoError(t, r.err)
	require.Len(t, a.Requests(), 1)
	req := a.Requests()[0]
	assert.Equal(t, []string{"create_target", "list_targets"}, req.Tools, "requested ∩ admitted")
	assert.Equal(t, "strong", req.Tier)
	assert.Equal(t, "file the open items", req.Instruction)
	assert.Equal(t, int64(42), req.RunID)
	assert.False(t, req.DryRun)
	assert.True(t, req.Binding.AutomationAgent)
	assert.Equal(t, int64(42), req.Binding.AutomationRunID)
	assert.Equal(t, tools.AutomationSurface, req.Binding.Surface)
	assert.NotNil(t, req.Manifest)
	assert.Equal(t, "filed one|["+jsonInt(made)+"]", r.out)

	steps := r.env.Journal.Steps()
	require.Len(t, steps, 1)
	assert.Equal(t, "fake", steps[0].Name)
	assert.Equal(t, "agent:run", steps[0].Permission)
	assert.JSONEq(t, `{"instruction":"file the open items","tools":["create_target","list_targets"],"budget":{"tokens":50000,"minutes":5},"tier":"strong"}`,
		steps[0].ArgsJSON)
	assert.JSONEq(t, `{"text":"filed one","actions":[`+jsonInt(made)+`]}`, steps[0].ResultSummary)

	// No tools option = every admitted tool; a dry run drops the writes.
	a = &automationstest.FakeAgent{}
	c = agentCase(t, a, nil, "agent:run", "llm:light", "tool:list_targets", "tool:create_target")
	c.dryRun = true
	mustReturn(t, `agent("x"); return "ok"`, c, "ok")
	require.Len(t, a.Requests(), 1)
	assert.Equal(t, []string{"list_targets"}, a.Requests()[0].Tools)
	assert.True(t, a.Requests()[0].DryRun)
}

func jsonInt(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestAgent_RunnerErrorsAndNotAvailable(t *testing.T) {
	mustReturn(t, `try { agent("x"); return "ran" } catch (e) { return e.name }`,
		agentCase(t, nil, nil, "agent:run", "llm:light"), "NotAvailable")
	a := &automationstest.FakeAgent{Err: errors.New("claude exited 1")}
	mustReturn(t, `try { agent("x"); return "ran" } catch (e) { return e.name + "|" + e.message }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "ToolError|agent(): claude exited 1")
	mustReturn(t, `try { agent(""); return "ran" } catch (e) { return e.name }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "ValidationError")
}

// The carve's own minutes running out is the agent's budget, not the run's:
// a catchable BudgetExceeded, and the run goes on.
func TestAgent_CarvedDeadlineThrowsCatchableBudgetExceeded(t *testing.T) {
	a := &automationstest.FakeAgent{UntilDone: true}
	r := mustReturn(t, `try { agent("x", {budget: {minutes: 1}}); return "ran" } catch (e) { return e.name + "|" + e.message + "|" + llm("after") }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "BudgetExceeded|agent(): its time budget is spent|ok")
	assert.Empty(t, r.env.Meter.Crossed())
	require.Len(t, a.Requests(), 1)

	// The run's own deadline stays uncatchable: when it ends before the
	// carve's minutes, the run is interrupted on time, not handed a
	// catchable BudgetExceeded.
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	c := agentCase(t, &automationstest.FakeAgent{UntilDone: true}, nil, "agent:run", "llm:light")
	c.backends.Clock = clock
	c.meter = automations.NewMeter(automations.Budget{Tokens: 50000, Minutes: 5}, clock)
	clock.Advance(5*time.Minute - time.Second) // one real second of the run is left
	r = runSDK(t, `try { agent("x", {budget: {minutes: 2}}); return "ran" } catch (e) { return "caught " + e.name }`, c)
	var ri *automations.RunInterrupted
	require.ErrorAs(t, r.err, &ri, "out = %v", r.out)
	assert.Equal(t, automations.InterruptTimeout, ri.Reason)
}

// A runner metered only after the fact (a CLI child) that overshoots its
// carve throws a catchable BudgetExceeded; its reply is not returned.
func TestAgent_OvershotCarveThrowsCatchableBudgetExceeded(t *testing.T) {
	a := &automationstest.FakeAgent{RunnerName: "claude", Result: automations.AgentResult{Text: "secret reply", InputTokens: 900, OutputTokens: 200}}
	r := mustReturn(t, `try { return agent("x", {budget: {tokens: 1000}}).text } catch (e) { return e.name + "|" + e.message + "|" + llm("after") }`,
		agentCase(t, a, nil, "agent:run", "llm:light"), "BudgetExceeded|agent(): it spent 1100 tokens, over its budget of 1000|ok")
	assert.Empty(t, r.env.Meter.Crossed(), "the run's budget was not crossed")
	steps := r.env.Journal.Steps()
	require.Len(t, steps, 2)
	assert.Equal(t, 1100, stepTokens(steps[0]), "what it spent is debited")
	assert.NotContains(t, steps[0].ResultSummary, "secret reply")
}
