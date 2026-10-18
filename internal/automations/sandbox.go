package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// scriptSrcName names the compiled script in goja stack frames.
const scriptSrcName = "recipe"

// maxCallStackDepth bounds JS recursion: deeper is an uncatchable
// RangeError, so runaway recursion cannot grow memory until the deadline.
const maxCallStackDepth = 2000

// Waiter pauses a run until ready reports true (spec §7.6): it sets the run
// waiting, pauses the meter, polls ready every PollInterval or on a wake, and
// resumes. The executor provides it (Task 10).
type Waiter interface {
	Wait(ctx context.Context, reason string, ready func(context.Context) (bool, error)) error
}

// Env is what every SDK function sees. NewSandbox replaces Ctx with a child
// that Interrupt cancels, so a pending backend call stops with the script.
type Env struct {
	Ctx        context.Context
	Run        *db.AutomationRun
	Automation *db.Automation
	Recipe     *Recipe
	Manifest   *Manifest
	DryRun     bool
	Journal    *Journal
	Meter      *Meter
	Buffer     *CommitBuffer
	Wait       Waiter
	Trigger    TriggerInfo
}

// Binding is the registry binding of this run's tool calls (spec §6.1). A
// workbench automation's binding carries its WorkbenchID, which scopes its
// reads and writes (the registry re-resolves it from the run at Apply).
func (e *Env) Binding() tools.Binding {
	b := tools.Binding{Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType}
	if e.Run != nil {
		b.ContextID = strconv.FormatInt(e.Run.ID, 10)
		b.AutomationRunID = e.Run.ID
	}
	switch {
	case e.Automation != nil:
		b.WorkbenchID = e.Automation.ProjectID
	case e.Recipe != nil:
		b.WorkbenchID = e.Recipe.Scope.WorkbenchID
	}
	return b
}

// encodedResult is an SDK result already serialised and size-checked.
type encodedResult json.RawMessage

// Call journals one SDK call: it begins a step, runs fn, serialises and
// size-checks the result, and closes the step — ok, denied for a
// PermissionDenied, error otherwise — unless fn closed it itself (a dry-run
// write, a proposal). A result beyond MaxSDKResultBytes fails the call and
// the step with ResultTooLarge; nothing is truncated. A run's call past
// MaxStepsPerRun is an error step and ends the run (errStepCap).
func (e *Env) Call(kind, name string, args any, fn func(step *Step) (any, error)) (any, error) {
	if e.Journal.Count() >= MaxStepsPerRun {
		// The call past the cap is journaled, then ends the run (the
		// sandbox aborts on the ScriptError): a looping script cannot
		// write steps for its whole budget (board #562).
		e.Journal.Begin(kind, name, args).Fail(errStepCap)
		return nil, errStepCap
	}
	step := e.Journal.Begin(kind, name, args)
	step.holdFinish()
	v, err := fn(step)
	var encErr error
	if err == nil {
		v, encErr = encodeSDKResult(v)
		err = encErr
	}
	if step.releaseFinish(encErr) {
		return v, err // fn closed the step; a failed encoding re-closes it as error
	}
	switch needed, isDenied := deniedEntry(err); {
	case err == nil:
		step.OK(v)
	case isDenied:
		step.Denied(needed)
	default:
		step.Fail(err)
	}
	return v, err
}

// ModelUsage is what one model call reports.
type ModelUsage struct {
	InputTokens, OutputTokens int64
	Estimated                 bool
	ReportedUSD               *float64 // nil = the provider reported no cost
}

// MeteredModelCall runs one model call under the meter: Meter.BeforeCall →
// call → Meter.Debit → step.Usage. The usage call reports is debited even
// when it also returns an error.
func (e *Env) MeteredModelCall(step *Step, call func(ctx context.Context) (ModelUsage, error)) error {
	if err := e.Meter.BeforeCall(); err != nil {
		return err
	}
	u, err := call(e.Ctx)
	e.Meter.Debit(u.InputTokens, u.OutputTokens)
	step.Usage(u.InputTokens, u.OutputTokens, u.Estimated, u.ReportedUSD)
	return err
}

// deniedEntry reports whether err is a permission denial and what it needed.
func deniedEntry(err error) (string, bool) {
	var pd *PermissionDenied
	if errors.As(err, &pd) {
		return pd.Needed, true
	}
	var se *SDKError
	if errors.As(err, &se) && se.Name == ErrNamePermissionDenied {
		return se.Needed, true
	}
	return "", false
}

// ErrSDKContract marks an SDK function that broke the seam's contract (it
// returned a JS value instead of a plain Go value): the run ends.
var ErrSDKContract = errors.New("automation SDK contract violation")

// encodeSDKResult serialises a plain Go value once (already encoded results
// pass through). A goja.Value is refused: the sandbox builds every JS value
// the script sees from JSON, so no Go object or JS value from elsewhere leaks
// in.
func encodeSDKResult(v any) (any, error) {
	switch v.(type) {
	case nil, encodedResult:
		return v, nil
	case goja.Value:
		return nil, fmt.Errorf("%w: an SDK function returned a JS value (%T)", ErrSDKContract, v)
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, &SDKError{Name: ErrNameTool, Message: "the result is not JSON: " + err.Error()}
	}
	if len(raw) > MaxSDKResultBytes {
		return nil, &SDKError{Name: ErrNameResultTooLarge,
			Message: fmt.Sprintf("the result is %d bytes; the limit is %d", len(raw), MaxSDKResultBytes)}
	}
	return encodedResult(raw), nil
}

// SDKFunc implements one SDK path. It returns a plain Go value (serialised
// to JSON and rebuilt as a fresh JS value at the boundary; never a goja.Value)
// or an error that becomes a JS Error (SDKError/PermissionDenied keep their
// name, others are ToolError).
type SDKFunc func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error)

// Module installs SDK paths.
type Module interface {
	Name() string
	Install(def Definer)
}

// Definer collects SDK paths. Paths are dotted (`llm`, `state.get`,
// `output.inbox`); a later Define of an already defined path replaces the
// earlier one (the later module in DefaultModules order wins).
type Definer interface {
	Define(path string, fn SDKFunc)
}

type definer struct {
	fns map[string]SDKFunc
	err error
}

func (d *definer) Define(path string, fn SDKFunc) {
	if !validSDKPath(path) || fn == nil {
		if d.err == nil {
			d.err = fmt.Errorf("invalid SDK definition %q", path)
		}
		return
	}
	d.fns[path] = fn
}

func validSDKPath(path string) bool {
	for seg := range strings.SplitSeq(path, ".") {
		if seg == "" || strings.ContainsAny(seg, " \t\n") {
			return false
		}
	}
	return true
}

// TriggerInfo is the script's read-only `trigger` object. Events is nil
// (trigger.events undefined) for every run but an event run.
type TriggerInfo struct {
	Kind         string
	RunID        int64
	ScheduledFor *time.Time
	CatchUp      bool
	Button       string
	Events       []map[string]any
	Truncated    bool
	DryRun       bool
}

func (t TriggerInfo) jsObject() map[string]any {
	m := map[string]any{
		"kind": t.Kind, "run_id": t.RunID, "catch_up": t.CatchUp, "truncated": t.Truncated, "dry_run": t.DryRun,
	}
	if t.ScheduledFor != nil {
		m["scheduled_for"] = t.ScheduledFor.Format(time.RFC3339)
	}
	if t.Button != "" {
		m["button"] = t.Button
	}
	if t.Events != nil {
		m["events"] = t.Events
	}
	return m
}

// errStepCap is what Env.Call returns for a call past MaxStepsPerRun; the
// sandbox aborts on it (errTooManySteps), so the script cannot catch it.
var errStepCap = fmt.Errorf("the run made more than %d SDK calls; the limit is %d per run", MaxStepsPerRun, MaxStepsPerRun)

// errTooManySteps is the run's end after errStepCap.
func errTooManySteps() *ScriptError {
	return &ScriptError{Name: "RangeError", Message: errStepCap.Error()}
}
