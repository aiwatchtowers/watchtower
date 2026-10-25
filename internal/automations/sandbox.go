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
	// ConversationID is the chat conversation an in-memory draft dry run
	// serves (draft_automation): its run has no id, so its reads spend that
	// conversation's read budget instead (READ-01). Zero elsewhere.
	ConversationID int64
	// Replay records a live run's replay log and plays a resumed run's back
	// (nil = neither: a dry run, a test env). The sandbox's clock reads
	// through it.
	Replay *Replay
	// capturePrompt and stopAtModelCalls are a capture dry run's
	// (DryRunOptions.CapturePrompts, StopAtModelCalls); unset otherwise.
	capturePrompt    func(primitive, prompt string)
	stopAtModelCalls bool
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
	b.ConversationID = e.ConversationID
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
//
// A live run records the call in its replay log with the step's close. A
// resumed run's call that the log already holds is answered from it: fn
// does not run and no step is written (AUTO-11); the call it waited in runs
// fn on its adopted open step, which re-enters the wait.
func (e *Env) Call(kind, name string, args any, fn func(step *Step) (any, error)) (any, error) {
	return e.call(kind, name, args, callOpts{}, fn)
}

// CallWithReplayKey is Call for an SDK function whose step args hold values
// it derived (a carved budget, a resolved default agent, the provider's
// name): the replay checks a resumed run's call by key — what the script
// itself asked for — and its kind, not by the derived args and name, which
// may differ in the next daemon life without the script having changed.
func (e *Env) CallWithReplayKey(kind, name string, args, key any, fn func(step *Step) (any, error)) (any, error) {
	return e.call(kind, name, args, callOpts{keyed: true, key: key}, fn)
}

// callOpts tunes one call's replay: buffered (CallBuffered) or keyed by key
// (CallWithReplayKey).
type callOpts struct {
	buffered bool
	keyed    bool
	key      any
}

// CallBuffered is Call for an SDK function whose only effect is on the
// run's commit buffer (state.set, a buffered output): a resumed run's replay
// runs fn again on a scratch step that is never written, so the buffer the
// run commits is rebuilt (AUTO-04), and the call's record is still what the
// script gets.
func (e *Env) CallBuffered(kind, name string, args any, fn func(step *Step) (any, error)) (any, error) {
	return e.call(kind, name, args, callOpts{buffered: true}, fn)
}

func (e *Env) call(kind, name string, args any, opts callOpts, fn func(step *Step) (any, error)) (any, error) {
	if e.Journal.Count() >= MaxStepsPerRun {
		// The call past the cap is journaled, then ends the run (the
		// sandbox aborts on the ScriptError): a looping script cannot
		// write steps for its whole budget (board #562).
		e.Journal.Begin(kind, name, args).Fail(errStepCap)
		return nil, errStepCap
	}
	if e.stopsAtModelCall(kind, name) {
		fn = func(step *Step) (any, error) {
			dryRunResult(step, map[string]any{"note": ModelCallStop})
			return nil, &RunInterrupted{Reason: InterruptModelCallStop}
		}
	}
	step, played, err := e.beginStep(kind, name, args, opts)
	if err != nil {
		return nil, err
	}
	if played != nil {
		return e.replayCall(kind, name, opts.buffered, played, fn)
	}
	step.holdFinish()
	v, err := fn(step)
	if errors.Is(err, errDaemonStopping) {
		step.dropHold() // the step stays open and waiting for the resume
		return nil, err
	}
	var encErr error
	if err == nil {
		v, encErr = encodeSDKResult(v)
		err = encErr
	}
	step.recordOutcome(v, err)
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

// beginStep begins the call's step. A recorded run's step starts its replay
// row; a resumed run's playback answers the call from its log (played) or
// adopts the open waiting step, or reports a divergence.
func (e *Env) beginStep(kind, name string, args any, opts callOpts) (*Step, *replayed, error) {
	r := e.Replay
	if r == nil || e.DryRun {
		return e.Journal.Begin(kind, name, args), nil, nil
	}
	hash := argsHash(args)
	if opts.keyed {
		hash = argsHash(map[string]any{"replay_key": opts.key})
	}
	if r.Live() {
		step := e.Journal.Begin(kind, name, args)
		clock, ok := r.takeClock()
		step.record(hash, clock, ok)
		return step, nil, nil
	}
	step, played, err := r.next(e.Journal, kind, name, hash, !opts.keyed)
	if step != nil {
		if rw, ok := e.Ctx.Value(runWaitKey{}).(*runWait); ok {
			rw.resumeAt(step.started) // pause_timeout_hours counts from the original wait
		}
	}
	return step, played, err
}

// replayCall answers a call from the resumed run's log. A buffered call runs
// fn on a scratch step first, so the commit buffer is rebuilt; an outcome
// that differs from the record (it threw then, not now, or the other way)
// is a divergence.
func (e *Env) replayCall(kind, name string, buffered bool, played *replayed,
	fn func(step *Step) (any, error)) (any, error) {
	if buffered {
		_, err := fn(NewMemoryJournal().Begin(kind, name, nil))
		if (err != nil) != (played.rec.ErrorJSON != "") {
			return nil, played.r.diverge(played.rec.Seq)
		}
	}
	return played.value()
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
	// vals are plain read-only values (builtin.input), installed as frozen
	// JSON copies.
	vals map[string]any
	err  error
}

// envModule is a Module whose paths depend on the run (its manifest): the
// sandbox installs it with installFor instead of Install.
type envModule interface {
	installFor(env *Env, d *definer)
}

// defineValue defines a plain value at path (a later definition replaces
// an earlier one).
func (d *definer) defineValue(path string, v any) {
	if !validSDKPath(path) {
		if d.err == nil {
			d.err = fmt.Errorf("invalid SDK definition %q", path)
		}
		return
	}
	if d.vals == nil {
		d.vals = map[string]any{}
	}
	d.vals[path] = v
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
// (trigger.events undefined) for every run but an event run; Reply is nil
// (trigger.reply undefined) for every run but a reply run, where it holds
// output_id, action, value, data and card {title, link}. Builtin is a slot
// run's input (event_json's "builtin"), which the script reads as
// builtin.input, not on trigger.
type TriggerInfo struct {
	Builtin      BuiltinInput
	Kind         string
	RunID        int64
	ScheduledFor *time.Time
	CatchUp      bool
	Button       string
	Events       []map[string]any
	Truncated    bool
	DryRun       bool
	Reply        map[string]any
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
	if t.Reply != nil {
		m["reply"] = t.Reply
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
