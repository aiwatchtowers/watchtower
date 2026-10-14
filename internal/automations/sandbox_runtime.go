package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/dop251/goja"
	"github.com/dop251/goja/parser"
)

// returnHookParam is the parameter through which the wrapped program gets
// the native return hook (see wrapScript); the script's own function
// shadows it, so the script cannot reach the hook.
const returnHookParam = "$__automationReturn"

// deepFreezeJS freezes an object graph (the trigger, SDK namespaces).
const deepFreezeJS = `(function f(o) {
	Object.getOwnPropertyNames(o).forEach(function (k) {
		var v = o[k];
		if (v !== null && typeof v === "object" && !Object.isFrozen(v)) { f(v); }
	});
	return Object.freeze(o);
})`

// Sandbox is one run's goja runtime. Its only world is the ECMAScript
// builtins (minus eval, Function and Promise), `trigger` and the SDK
// modules: no require, console, timers, network or file system.
type Sandbox struct {
	env        *Env
	rt         *goja.Runtime
	prog       *goja.Program
	scriptLine int
	errorCtor  goja.Value
	jsonParse  goja.Callable
	returnJSON goja.Callable
	freeze     goja.Callable
	cancel     context.CancelFunc
	parentDone <-chan struct{}
	stopped    chan struct{} // closed by the first Interrupt or abort
	stopOnce   sync.Once

	mu       sync.Mutex
	reason   InterruptReason
	fatal    error
	ran      bool
	finished bool // the script returned: no SDK call may follow
	returned any
}

// NewSandbox prepares a fresh runtime for env.Recipe's script with modules
// installed in order. env needs Ctx, Recipe, Journal and Meter; a journal
// without its own clock adopts the meter's.
func NewSandbox(env *Env, modules []Module) (*Sandbox, error) {
	if env == nil || env.Ctx == nil || env.Recipe == nil || env.Journal == nil || env.Meter == nil {
		return nil, errors.New("automation sandbox: env needs Ctx, Recipe, Journal and Meter")
	}
	if err := PreParse(env.Recipe.Script); err != nil {
		return nil, err
	}
	s := &Sandbox{env: env, rt: goja.New(), scriptLine: max(env.Recipe.ScriptLine, 1),
		parentDone: env.Ctx.Done(), stopped: make(chan struct{})}
	prog, err := s.compile(env.Recipe.Script)
	if err != nil {
		return nil, err
	}
	s.prog = prog
	env.Journal.adoptClock(env.Meter.clock)
	env.Ctx, s.cancel = context.WithCancel(env.Ctx)
	if err := s.setup(modules); err != nil {
		s.cancel()
		return nil, err
	}
	return s, nil
}

func (s *Sandbox) compile(script string) (*goja.Program, error) {
	src := wrapScript(script)
	parsed, err := parser.ParseFile(nil, scriptSrcName, src, 0)
	if err != nil {
		return nil, s.syntaxError(err)
	}
	if !wrapperIntact(parsed, src) {
		return nil, &ScriptError{Name: "SyntaxError", Message: errWrapperBroken}
	}
	prog, err := goja.CompileAST(parsed, false)
	if err != nil {
		return nil, s.syntaxError(err)
	}
	return prog, nil
}

func (s *Sandbox) setup(modules []Module) error {
	rt := s.rt
	rt.SetMaxCallStackSize(maxCallStackDepth)
	s.errorCtor = rt.Get("Error")
	var err error
	if s.jsonParse, err = s.callable(`JSON.parse`); err != nil {
		return err
	}
	if s.freeze, err = s.callable(deepFreezeJS); err != nil {
		return err
	}
	if err := s.lockdown(); err != nil {
		return err
	}
	makeReturnJSON, err := s.callable(returnJSONJS)
	if err != nil {
		return err
	}
	rj, err := makeReturnJSON(goja.Undefined(), rt.Get("JSON").ToObject(rt).Get("stringify"), s.errorCtor, rt.Get("String"))
	if err != nil {
		return fmt.Errorf("automation sandbox: building the return serialiser: %w", err)
	}
	if s.returnJSON, err = asCallable(rj, "the return serialiser"); err != nil {
		return err
	}
	if err := s.installTrigger(); err != nil {
		return err
	}
	return s.installModules(modules)
}

// callable evaluates src (setup code, never the script) to a function.
func (s *Sandbox) callable(src string) (goja.Callable, error) {
	v, err := s.rt.RunString(src)
	if err != nil {
		return nil, fmt.Errorf("automation sandbox: evaluating setup code: %w", err)
	}
	return asCallable(v, src)
}

func asCallable(v goja.Value, what string) (goja.Callable, error) {
	fn, ok := goja.AssertFunction(v)
	if !ok {
		return nil, fmt.Errorf("automation sandbox: %.40s is not callable", what)
	}
	return fn, nil
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

// wrap adapts fn to goja: Go panics and contract breaks end the run, the
// meter's interrupts stop it, errors become JS Errors, results become fresh
// plain JS values.
func (s *Sandbox) wrap(path string, fn SDKFunc) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		if s.isFinished() {
			// Only the script's own code (a getter or toJSON run while its
			// return value is serialised) can call here: a script error.
			s.abort(&ScriptError{Name: ErrNameValidation,
				Message: path + "() was called while the script's return value was being serialised"})
			return goja.Undefined()
		}
		v, err := s.invoke(path, fn, call)
		if r := s.env.Meter.Crossed(); r != "" {
			s.Interrupt(r)
		}
		if err == nil {
			v, err = s.toJS(v)
		}
		if errors.Is(err, ErrSDKContract) {
			s.abort(fmt.Errorf("%s: %w", path, err))
			return goja.Undefined()
		}
		if err != nil {
			return s.throw(err)
		}
		return v.(goja.Value)
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

// throw raises err in the script (it does not return, except after an
// interrupt, when the VM stops at its next instruction anyway).
func (s *Sandbox) throw(err error) goja.Value {
	var ri *RunInterrupted
	if errors.As(err, &ri) {
		s.Interrupt(ri.Reason)
		return goja.Undefined()
	}
	if s.interrupted() {
		return goja.Undefined() // the backend call was cut short by the interrupt
	}
	panic(s.newJSError(jsErrorParts(err)))
}

func (s *Sandbox) newJSError(name, msg, needed string) *goja.Object {
	obj, err := s.rt.New(s.errorCtor, s.rt.ToValue(msg))
	if err != nil {
		panic(err)
	}
	_ = obj.Set("name", name) // a fresh Error object: Set cannot fail
	if needed != "" {
		_ = obj.Set("needed", needed)
	}
	return obj
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

// toJS turns an SDK result into a fresh plain JS value (JSON round trip,
// size checked unless Env.Call already did).
func (s *Sandbox) toJS(v any) (any, error) {
	enc, err := encodeSDKResult(v)
	if err != nil {
		return nil, err
	}
	if enc == nil {
		return goja.Undefined(), nil
	}
	return s.jsonParse(goja.Undefined(), s.rt.ToValue(string(enc.(encodedResult))))
}

// scriptReturned receives the script's return value inside the running
// program, so serialising it (getters, toJSON) stays under the interrupt.
func (s *Sandbox) scriptReturned(call goja.FunctionCall) goja.Value {
	s.mu.Lock()
	s.finished = true
	s.mu.Unlock()
	out, err := s.returnJSON(goja.Undefined(), call.Argument(0))
	if err != nil {
		panic(err) // a ValidationError, a getter's throw or an interrupt
	}
	if goja.IsUndefined(out) {
		return goja.Undefined()
	}
	text := out.String()
	if len(text) > MaxSDKResultBytes {
		panic(s.newJSError(ErrNameResultTooLarge,
			fmt.Sprintf("the script's return value is %d bytes; the limit is %d", len(text), MaxSDKResultBytes), ""))
	}
	var v any
	if err := json.Unmarshal([]byte(text), &v); err != nil {
		panic(s.newJSError(ErrNameValidation, "the script's return value is not JSON: "+err.Error(), ""))
	}
	s.mu.Lock()
	s.returned = v
	s.mu.Unlock()
	return goja.Undefined()
}

func (s *Sandbox) isFinished() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished
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
	s.stop()
}

func (s *Sandbox) abort(err error) {
	s.mu.Lock()
	if s.fatal == nil {
		s.fatal = err
	}
	s.mu.Unlock()
	s.rt.Interrupt(err)
	s.stop()
}

func (s *Sandbox) stop() {
	s.cancel()
	s.stopOnce.Do(func() { close(s.stopped) })
}

func (s *Sandbox) interrupted() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reason != "" || s.fatal != nil
}
