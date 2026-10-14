package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"github.com/dop251/goja/parser"

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

// Binding is the registry binding of this run's tool calls (spec §6.1).
func (e *Env) Binding() tools.Binding {
	b := tools.Binding{Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType}
	if e.Run != nil {
		b.ContextID = strconv.FormatInt(e.Run.ID, 10)
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
// the step with ResultTooLarge; nothing is truncated.
func (e *Env) Call(kind, name string, args any, fn func(step *Step) (any, error)) (any, error) {
	step := e.Journal.Begin(kind, name, args)
	v, err := fn(step)
	if err == nil {
		v, err = encodeSDKResult(v)
	}
	if step.Finished() {
		return v, err
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

// encodeSDKResult serialises v once; JS values and already encoded results
// pass through.
func encodeSDKResult(v any) (any, error) {
	switch v.(type) {
	case nil, goja.Value, encodedResult:
		return v, nil
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

// SDKFunc implements one SDK path. It returns a Go value (serialised to a
// plain JS value at the boundary), a goja.Value, or an error that becomes a
// JS Error (SDKError/PermissionDenied keep their name, others are ToolError).
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
	for _, seg := range strings.Split(path, ".") {
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

// deepFreezeJS freezes an object graph (the trigger, SDK namespaces).
const deepFreezeJS = `(function f(o) {
	Object.getOwnPropertyNames(o).forEach(function (k) {
		var v = o[k];
		if (v !== null && typeof v === "object" && !Object.isFrozen(v)) { f(v); }
	});
	return Object.freeze(o);
})`

// Sandbox is one run's goja runtime. Its only world is the ECMAScript
// builtins, `trigger` and the SDK modules: no require, console, timers,
// Promise, network or file system.
type Sandbox struct {
	env        *Env
	rt         *goja.Runtime
	prog       *goja.Program
	scriptLine int
	errorCtor  goja.Value
	jsonParse  goja.Callable
	freeze     goja.Callable
	cancel     context.CancelFunc
	parentDone <-chan struct{}

	mu     sync.Mutex
	reason InterruptReason
	fatal  error
	ran    bool
}

// NewSandbox prepares a fresh runtime for env.Recipe's script with modules
// installed in order. env needs Ctx, Recipe, Journal and Meter.
func NewSandbox(env *Env, modules []Module) (*Sandbox, error) {
	if env == nil || env.Ctx == nil || env.Recipe == nil || env.Journal == nil || env.Meter == nil {
		return nil, errors.New("automation sandbox: env needs Ctx, Recipe, Journal and Meter")
	}
	if err := PreParse(env.Recipe.Script); err != nil {
		return nil, err
	}
	s := &Sandbox{env: env, rt: goja.New(), scriptLine: max(env.Recipe.ScriptLine, 1), parentDone: env.Ctx.Done()}
	parsed, err := parser.ParseFile(nil, scriptSrcName, wrapScript(env.Recipe.Script), 0)
	if err != nil {
		return nil, s.syntaxError(err)
	}
	prog, err := goja.CompileAST(parsed, false)
	if err != nil {
		return nil, s.syntaxError(err)
	}
	s.prog = prog
	env.Ctx, s.cancel = context.WithCancel(env.Ctx)
	if err := s.setup(modules); err != nil {
		s.cancel()
		return nil, err
	}
	return s, nil
}

// wrapScript makes the script a strict function body (so it may `return`)
// without moving its lines: the prefix sits on the script's first line.
func wrapScript(script string) string {
	return `(function () {"use strict";` + script + "\n})()"
}

func (s *Sandbox) setup(modules []Module) error {
	rt := s.rt
	rt.SetMaxCallStackSize(maxCallStackDepth)
	if err := rt.GlobalObject().Delete("Promise"); err != nil {
		return fmt.Errorf("automation sandbox: removing Promise: %w", err)
	}
	s.errorCtor = rt.Get("Error")
	var ok bool
	if s.jsonParse, ok = goja.AssertFunction(rt.Get("JSON").ToObject(rt).Get("parse")); !ok {
		return errors.New("automation sandbox: JSON.parse is not callable")
	}
	freeze, err := rt.RunString(deepFreezeJS)
	if err != nil {
		return fmt.Errorf("automation sandbox: compiling the freeze helper: %w", err)
	}
	if s.freeze, ok = goja.AssertFunction(freeze); !ok {
		return errors.New("automation sandbox: the freeze helper is not callable")
	}
	if err := s.installTrigger(); err != nil {
		return err
	}
	return s.installModules(modules)
}

func (s *Sandbox) installTrigger() error {
	raw, err := json.Marshal(s.env.Trigger.jsObject())
	if err != nil {
		return fmt.Errorf("automation sandbox: encoding trigger: %w", err)
	}
	obj, err := s.jsonParse(goja.Undefined(), s.rt.ToValue(string(raw)))
	if err != nil {
		return fmt.Errorf("automation sandbox: building trigger: %w", err)
	}
	if obj, err = s.freeze(goja.Undefined(), obj); err != nil {
		return fmt.Errorf("automation sandbox: freezing trigger: %w", err)
	}
	return s.defineGlobal(s.rt.GlobalObject(), "trigger", obj)
}

func (s *Sandbox) defineGlobal(parent *goja.Object, name string, v goja.Value) error {
	if err := parent.DefineDataProperty(name, v, goja.FLAG_FALSE, goja.FLAG_TRUE, goja.FLAG_FALSE); err != nil {
		return fmt.Errorf("automation sandbox: defining %s: %w", name, err)
	}
	return nil
}

func (s *Sandbox) installModules(modules []Module) error {
	d := &definer{fns: map[string]SDKFunc{}}
	for _, m := range modules {
		m.Install(d)
	}
	if d.err != nil {
		return fmt.Errorf("automation sandbox: %w", d.err)
	}
	paths := make([]string, 0, len(d.fns))
	for p := range d.fns {
		paths = append(paths, p)
	}
	// Parents before children, so `tool` exists before `tool.x` hangs on it.
	sort.Slice(paths, func(i, j int) bool {
		di, dj := strings.Count(paths[i], "."), strings.Count(paths[j], ".")
		return di < dj || (di == dj && paths[i] < paths[j])
	})
	var namespaces []goja.Value
	for _, p := range paths {
		created, err := s.installPath(p, d.fns[p])
		if err != nil {
			return err
		}
		namespaces = append(namespaces, created...)
	}
	for _, ns := range namespaces {
		if _, err := s.freeze(goja.Undefined(), ns); err != nil {
			return fmt.Errorf("automation sandbox: freezing an SDK namespace: %w", err)
		}
	}
	return nil
}

// installPath defines fn at path, creating namespace objects on the way; it
// returns the namespaces it created.
func (s *Sandbox) installPath(path string, fn SDKFunc) ([]goja.Value, error) {
	segs := strings.Split(path, ".")
	parent := s.rt.GlobalObject()
	var created []goja.Value
	for _, seg := range segs[:len(segs)-1] {
		next := parent.Get(seg)
		if next == nil || goja.IsUndefined(next) || goja.IsNull(next) {
			ns := s.rt.NewObject()
			if err := s.defineGlobal(parent, seg, ns); err != nil {
				return nil, err
			}
			created = append(created, ns)
			parent = ns
			continue
		}
		obj, ok := next.(*goja.Object)
		if !ok {
			return nil, fmt.Errorf("automation sandbox: %s: %q is not an object", path, seg)
		}
		parent = obj
	}
	return created, s.defineGlobal(parent, segs[len(segs)-1], s.rt.ToValue(s.wrap(path, fn)))
}

// wrap adapts fn to goja: Go panics end the run, the meter's interrupts stop
// it, errors become JS Errors, results become plain JS values.
func (s *Sandbox) wrap(path string, fn SDKFunc) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		v, err := s.invoke(path, fn, call)
		if r := s.env.Meter.Crossed(); r != "" {
			s.Interrupt(r)
		}
		if err != nil {
			return s.throw(err)
		}
		js, err := s.toJS(v)
		if err != nil {
			return s.throw(err)
		}
		return js
	}
}

// invoke runs fn, turning a Go panic (not a JS throw from goja itself) into
// a fatal, uncatchable end of the run.
func (s *Sandbox) invoke(path string, fn SDKFunc, call goja.FunctionCall) (v any, err error) {
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		switch r.(type) {
		case goja.Value, *goja.Exception, *goja.InterruptedError, *goja.StackOverflowError:
			panic(r) // a JS exception raised through the runtime: let goja handle it
		}
		s.abort(fmt.Errorf("%w: %s: %v", ErrSDKPanic, path, r))
		v, err = nil, nil
	}()
	return fn(s.env, call, s.rt)
}

// throw raises err in the script (it does not return).
func (s *Sandbox) throw(err error) goja.Value {
	var ri *RunInterrupted
	if errors.As(err, &ri) {
		s.Interrupt(ri.Reason)
		return goja.Undefined()
	}
	if s.interrupted() {
		return goja.Undefined() // the backend call was cut short by the interrupt
	}
	name, msg, needed := jsErrorParts(err)
	obj, cerr := s.rt.New(s.errorCtor, s.rt.ToValue(msg))
	if cerr != nil {
		panic(cerr)
	}
	_ = obj.Set("name", name) // a fresh Error object: Set cannot fail
	if needed != "" {
		_ = obj.Set("needed", needed)
	}
	panic(obj)
}

// jsErrorParts maps a Go error to a JS error's name, message and `needed`.
func jsErrorParts(err error) (name, msg, needed string) {
	var pd *PermissionDenied
	var se *SDKError
	switch {
	case errors.As(err, &pd):
		msg = "permission denied: the recipe needs " + pd.Needed
		if pd.Reason != "" {
			msg = "permission denied: " + pd.Reason
		}
		return ErrNamePermissionDenied, msg, pd.Needed
	case errors.As(err, &se):
		return se.Name, se.Message, se.Needed
	default:
		return ErrNameTool, err.Error(), ""
	}
}

// toJS turns an SDK result into a plain JS value (JSON round trip, size
// checked unless Env.Call already did).
func (s *Sandbox) toJS(v any) (goja.Value, error) {
	enc, err := encodeSDKResult(v)
	if err != nil {
		return nil, err
	}
	switch x := enc.(type) {
	case nil:
		return goja.Undefined(), nil
	case goja.Value:
		return x, nil
	case encodedResult:
		return s.jsonParse(goja.Undefined(), s.rt.ToValue(string(x)))
	}
	return nil, fmt.Errorf("automation sandbox: unexpected result type %T", enc)
}

// Interrupt stops the script at its next instruction; JS catch cannot
// intercept it. The first reason wins. It also cancels Env.Ctx.
func (s *Sandbox) Interrupt(reason InterruptReason) {
	s.mu.Lock()
	if s.reason == "" {
		s.reason = reason
	}
	s.mu.Unlock()
	s.rt.Interrupt(reason)
	s.cancel()
}

func (s *Sandbox) abort(err error) {
	s.mu.Lock()
	if s.fatal == nil {
		s.fatal = err
	}
	s.mu.Unlock()
	s.rt.Interrupt(err)
	s.cancel()
}

func (s *Sandbox) interrupted() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reason != "" || s.fatal != nil
}

// Run executes the script once. It returns the script's return value
// (exported to Go), or a *RunInterrupted, a *ScriptError, or an ErrSDKPanic
// error.
func (s *Sandbox) Run() (returned any, err error) {
	s.mu.Lock()
	if s.ran {
		s.mu.Unlock()
		return nil, errors.New("automation sandbox: Run called twice")
	}
	s.ran = true
	s.mu.Unlock()
	done, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		s.watchDeadline(done)
	}()
	defer func() {
		close(done)
		<-watched
		s.cancel()
	}()
	defer func() {
		if r := recover(); r != nil {
			returned, err = nil, fmt.Errorf("%w: %v", ErrSDKPanic, r)
		}
	}()
	v, runErr := s.rt.RunProgram(s.prog)
	return s.outcome(v, runErr)
}

func (s *Sandbox) outcome(v goja.Value, runErr error) (any, error) {
	s.mu.Lock()
	fatal, reason := s.fatal, s.reason
	s.mu.Unlock()
	if fatal != nil {
		return nil, fatal
	}
	var intr *goja.InterruptedError
	var overflow *goja.StackOverflowError
	var ex *goja.Exception
	switch {
	case runErr == nil:
		if v == nil {
			return nil, nil
		}
		return v.Export(), nil
	case errors.As(runErr, &intr):
		return nil, &RunInterrupted{Reason: reason}
	case errors.As(runErr, &overflow):
		return nil, &ScriptError{Name: "RangeError", Message: "maximum call stack size exceeded"}
	case errors.As(runErr, &ex):
		return nil, s.scriptError(ex)
	default:
		return nil, &ScriptError{Message: runErr.Error()}
	}
}

// watchDeadline interrupts the run at the meter's deadline (re-armed on
// pause/resume) or when the parent context ends.
func (s *Sandbox) watchDeadline(done <-chan struct{}) {
	m := s.env.Meter
	for {
		var timer *time.Timer
		var fired <-chan time.Time
		if !m.Paused() {
			left := m.Deadline().Sub(m.clock.Now())
			if left <= 0 {
				s.Interrupt(InterruptTimeout)
				return
			}
			timer = time.NewTimer(left)
			fired = timer.C
		}
		stop := s.awaitDeadline(done, fired)
		if timer != nil {
			timer.Stop()
		}
		if stop {
			return
		}
	}
}

// awaitDeadline waits for one event; it reports whether watching is over.
func (s *Sandbox) awaitDeadline(done <-chan struct{}, fired <-chan time.Time) bool {
	m := s.env.Meter
	select {
	case <-done:
		return true
	case <-s.parentDone:
		s.Interrupt(InterruptCancel)
		return true
	case <-m.rearm:
		return false
	case <-fired:
		if !s.deadlineStillDue(m) {
			return false
		}
		s.Interrupt(InterruptTimeout)
		return true
	}
}

// deadlineStillDue reports a fired timer that no pause/resume overtook.
func (s *Sandbox) deadlineStillDue(m *Meter) bool {
	select {
	case <-m.rearm:
		return false
	default:
		return !m.Paused()
	}
}

func (s *Sandbox) fileLine(jsLine int) int {
	if jsLine <= 0 {
		return 0
	}
	return s.scriptLine + jsLine - 1
}

func (s *Sandbox) syntaxError(err error) error {
	var list parser.ErrorList
	if errors.As(err, &list) && len(list) > 0 {
		return &ScriptError{Name: "SyntaxError", Message: list[0].Message, Line: s.fileLine(list[0].Position.Line)}
	}
	var ce *goja.CompilerSyntaxError
	if errors.As(err, &ce) && ce.File != nil {
		pos := ce.File.Position(ce.Offset)
		return &ScriptError{Name: "SyntaxError", Message: ce.Message, Line: s.fileLine(pos.Line)}
	}
	return &ScriptError{Name: "SyntaxError", Message: err.Error()}
}

// scriptError maps an uncaught exception to the recipe file's lines.
func (s *Sandbox) scriptError(ex *goja.Exception) *ScriptError {
	out := &ScriptError{Message: ex.Error()}
	if obj, ok := ex.Value().(*goja.Object); ok {
		out.Name = stringProp(obj, "name")
		if msg := obj.Get("message"); msg != nil && !goja.IsUndefined(msg) {
			out.Message = msg.String()
		}
	} else if v := ex.Value(); v != nil {
		out.Message = v.String()
	}
	var stack strings.Builder
	for _, f := range ex.Stack() {
		if f.SrcName() != scriptSrcName {
			fmt.Fprintf(&stack, "at %s (native)\n", f.FuncName())
			continue
		}
		pos := f.Position()
		line := s.fileLine(pos.Line)
		if out.Line == 0 {
			out.Line = line
		}
		fmt.Fprintf(&stack, "at %s (line %d:%d)\n", funcLabel(f.FuncName()), line, pos.Column)
	}
	out.Stack = strings.TrimSuffix(stack.String(), "\n")
	return out
}

func stringProp(obj *goja.Object, name string) string {
	if v := obj.Get(name); v != nil && !goja.IsUndefined(v) {
		return v.String()
	}
	return ""
}

func funcLabel(name string) string {
	if name == "" {
		return "<script>"
	}
	return name
}
