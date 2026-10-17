package automations

import (
	"context"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// agentStepClip bounds the instruction and the reply an agent step journals
// (the script still gets the whole reply).
const agentStepClip = 1024

// AgentModule defines agent(instruction, {tools?, budget?, tier?}) (spec §5,
// §6.5): agent:run and llm:<tier> (default light), the effective tool set
// (EffectiveAgentTools: no writes in a dry run), a budget carved from the
// run's remainder (a larger request is clamped), one Backends.Agent call
// metered per model call, and {text, actions} back, actions being the ids of
// the agent_actions rows the call proposed for this run. A spent carve stops
// the loop with a catchable BudgetExceeded; crossing the run's budget
// interrupts the run as an llm() call does. wait is refused: proposals stay
// pending.
func AgentModule(b Backends) Module {
	return sdkModule{name: "agent", fns: map[string]SDKFunc{"agent": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseAgentCall(env, rt, call)
		if reqErr == nil {
			req.carve(env, b)
			if env.Manifest != nil && b.Registry != nil {
				req.effective = EffectiveAgentTools(b.Registry, env.Manifest, req.tools, env.DryRun)
			}
		}
		name := "unavailable"
		if b.Agent != nil {
			name = b.Agent.Name()
		}
		return env.Call(StepKindAgent, name, req.stepArgs(), func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			return runAgent(env, b, step, req)
		})
	}}}
}

// agentCall is one agent() call's arguments and its carved budget.
type agentCall struct {
	instruction     string
	tools           []string // requested; nil = every admitted tool
	tier            string
	tokens, minutes int // requested; 0 = the run's remainder
	budget          Budget
	deadline        time.Time
	effective       []string
}

func (r agentCall) stepArgs() map[string]any {
	return map[string]any{
		"instruction": clipUTF8(r.instruction, agentStepClip),
		"tools":       r.effective,
		"budget":      map[string]int{"tokens": r.budget.Tokens, "minutes": r.budget.Minutes},
		"tier":        r.tier,
	}
}

// carve sets the call's budget from the run's remainder: tokens and minutes
// are the request clamped to it (the remainder when not asked for); the
// deadline is the run's, or the requested minutes from now when earlier.
func (r *agentCall) carve(env *Env, b Backends) {
	rem := env.Meter.Remaining()
	r.budget = rem
	if r.tokens > 0 {
		r.budget.Tokens = min(r.tokens, rem.Tokens)
	}
	r.deadline = env.Meter.Deadline()
	if r.minutes > 0 {
		r.budget.Minutes = min(r.minutes, rem.Minutes)
		var clock Clock = RealClock{}
		if b.Clock != nil {
			clock = b.Clock
		}
		if d := clock.Now().Add(time.Duration(r.minutes) * time.Minute); d.Before(r.deadline) {
			r.deadline = d
		}
	}
}

var agentOptionKeys = []string{"tools", "budget", "tier", "wait"}

// parseAgentCall reads agent(instruction, opts?). A bad call is reported
// inside the step.
func parseAgentCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (agentCall, error) {
	req := agentCall{tier: tierLight}
	v, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation, fmt.Sprintf("agent(): the instruction is larger than %d bytes", maxSDKArgBytes))
	}
	var ok bool
	if req.instruction, ok = v.(string); !ok || strings.TrimSpace(req.instruction) == "" {
		return req, validationf("agent(instruction): instruction must be a non-empty string")
	}
	o, present, err := argAt(env, rt, call, 1)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation, fmt.Sprintf("agent(): the options object is larger than %d bytes", maxSDKArgBytes))
	}
	if !present || o == nil {
		return req, nil
	}
	opts, ok := o.(map[string]any)
	if !ok {
		return req, validationf("agent(instruction, options): options must be an object")
	}
	return req, req.applyOptions(opts)
}

func (r *agentCall) applyOptions(opts map[string]any) error {
	for k := range opts {
		if !slices.Contains(agentOptionKeys, k) {
			return validationf("agent(): unknown option %q (use tools, budget, tier)", k)
		}
	}
	if _, has := opts["wait"]; has {
		return validationf("wait is not available inside agent()")
	}
	if t, has := opts["tier"]; has {
		s, ok := t.(string)
		if !ok || (s != tierLight && s != tierStrong) {
			return validationf("agent(): tier must be %q or %q", tierLight, tierStrong)
		}
		r.tier = s
	}
	if t, has := opts["tools"]; has {
		list, ok := t.([]any)
		if !ok {
			return validationf("agent(): tools must be an array of tool names")
		}
		r.tools = []string{}
		for _, el := range list {
			name, ok := el.(string)
			if !ok || name == "" {
				return validationf("agent(): tools must be an array of tool names")
			}
			r.tools = append(r.tools, name)
		}
	}
	if bv, has := opts["budget"]; has {
		return r.applyBudget(bv)
	}
	return nil
}

func (r *agentCall) applyBudget(v any) error {
	bm, ok := v.(map[string]any)
	if !ok {
		return validationf("agent(): budget must be an object {tokens?, minutes?}")
	}
	for k, val := range bm {
		n, ok := positiveInt(val)
		switch {
		case k != "tokens" && k != "minutes":
			return validationf("agent(): unknown budget key %q (use tokens, minutes)", k)
		case !ok:
			return validationf("agent(): budget.%s must be a positive integer", k)
		case k == "tokens":
			r.tokens = n
		default:
			r.minutes = n
		}
	}
	return nil
}

// positiveInt reads a script number that is a whole number above zero.
func positiveInt(v any) (int, bool) {
	switch n := v.(type) {
	case int64:
		return int(n), n > 0 && n <= math.MaxInt32
	case float64:
		return int(n), n > 0 && n <= math.MaxInt32 && n == math.Trunc(n)
	}
	return 0, false
}

const agentDraftNote = "agent() is not previewed in a draft; dry-run the saved recipe from its card to see it"

func runAgent(env *Env, b Backends, step *Step, req agentCall) (any, error) {
	m, err := authorizeAgent(env, b, step, req)
	if err != nil {
		return nil, err
	}
	if env.InMemoryDraft() {
		// A draft's in-memory dry run has no run row for the child's
		// server to bind to: spawn nothing, spend nothing.
		return dryRunResult(step, map[string]any{"note": agentDraftNote}), nil
	}
	floor, err := b.DB.MaxAgentActionID()
	if err != nil {
		return nil, err
	}
	binding := env.Binding()
	binding.AutomationAgent = true
	var spent agentSpend // what the hooks reported
	ar := AgentRequest{
		Instruction: req.instruction, Tools: req.effective, DryRun: env.DryRun, Tier: req.tier,
		Budget: req.budget, Deadline: req.deadline, Binding: binding, RunID: binding.AutomationRunID, Manifest: m,
		BeforeModelCall: func() error {
			if spent.in+spent.out >= int64(req.budget.Tokens) {
				return &SDKError{Name: ErrNameBudget, Message: "agent(): its token budget is spent"}
			}
			return env.Meter.BeforeCall()
		},
		AfterModelCall: func(in, out int) {
			spent.in, spent.out = spent.in+int64(in), spent.out+int64(out)
			env.Meter.Debit(int64(in), int64(out))
			step.Usage(int64(in), int64(out), false, nil)
		},
	}
	// The carve's own minutes, when they end before the run's deadline, are
	// the agent's budget: running out of them is a catchable BudgetExceeded.
	// The run's deadline stays the sandbox's interrupt.
	localDeadline := req.minutes > 0 && req.deadline.Before(env.Meter.Deadline())
	var res AgentResult
	err = env.MeteredModelCall(step, func(ctx context.Context) (ModelUsage, error) {
		r, u, err := runAgentChild(ctx, b.Agent, ar, req, localDeadline, &spent)
		res = r
		return u, err
	})
	if err != nil {
		return nil, err
	}
	actions, err := b.DB.AgentActionIDsAfter(tools.AutomationContextType, binding.ContextID, floor)
	if err != nil {
		return nil, err
	}
	step.Finish(db.StepFinish{Status: StepOK,
		ResultSummary: marshalForStep(map[string]any{"text": clipUTF8(res.Text, agentStepClip), "actions": actions})})
	return map[string]any{"text": res.Text, "actions": actions}, nil
}

// authorizeAgent checks the manifest admits agent() and its tier, records
// the permission on the step, and refuses when no runner is configured.
func authorizeAgent(env *Env, b Backends, step *Step, req agentCall) (*Manifest, error) {
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowCapability("agent", "run", "")
	if err != nil {
		return nil, err
	}
	if _, err := m.AllowLLM(req.tier); err != nil {
		return nil, err
	}
	step.SetPermission(entry)
	if b.Agent == nil || b.DB == nil || b.Registry == nil {
		return nil, notAvailable("no agent runner is configured")
	}
	return m, nil
}

// agentSpend is the tokens the runner's hooks reported during one agent().
type agentSpend struct{ in, out int64 }

// runAgentChild runs the agent under the carve's local deadline (when it
// ends first) and returns its result, the usage the hooks did not report,
// and the script-facing error: a spent time or token budget is a
// BudgetExceeded.
func runAgentChild(ctx context.Context, runner AgentRunner, ar AgentRequest, req agentCall, localDeadline bool, spent *agentSpend) (AgentResult, ModelUsage, error) {
	runCtx := ctx
	if localDeadline {
		var cancel context.CancelFunc
		runCtx, cancel = context.WithDeadline(ctx, req.deadline)
		defer cancel()
	}
	r, err := runner.Run(runCtx, ar)
	if err != nil && localDeadline && errors.Is(runCtx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
		err = &SDKError{Name: ErrNameBudget, Message: "agent(): its time budget is spent"}
	}
	// Debit what the hooks did not report (a CLI child's usage, an
	// estimate) once.
	u := ModelUsage{InputTokens: max(r.InputTokens-spent.in, 0), OutputTokens: max(r.OutputTokens-spent.out, 0)}
	if u.InputTokens+u.OutputTokens > 0 {
		u.Estimated, u.ReportedUSD = r.Estimated, r.ReportedCostUSD
	}
	// A runner metered only after the fact (a CLI child) can overshoot
	// the carve: its reply is then not returned.
	if total := spent.in + spent.out + u.InputTokens + u.OutputTokens; err == nil && total > int64(req.budget.Tokens) {
		err = &SDKError{Name: ErrNameBudget,
			Message: fmt.Sprintf("agent(): it spent %d tokens, over its budget of %d", total, req.budget.Tokens)}
	}
	return r, u, agentError(err)
}

// agentError is a runner failure as the script sees it: an SDK error (a
// spent budget) as is, anything else a ToolError.
func agentError(err error) error {
	if err == nil {
		return nil
	}
	var se *SDKError
	if errors.As(err, &se) {
		return se
	}
	return &SDKError{Name: ErrNameTool, Message: "agent(): " + err.Error()}
}
