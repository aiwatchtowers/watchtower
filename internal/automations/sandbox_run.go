package automations

import (
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/dop251/goja"
	"github.com/dop251/goja/ast"
	"github.com/dop251/goja/file"
	"github.com/dop251/goja/parser"
)

// AbandonGrace is how long Run waits, after an interrupt, for the script
// goroutine to stop. goja cannot preempt a native builtin (a huge
// Array.join, a deep JSON.stringify); past the grace Run returns and leaves
// that goroutine behind (AbandonedRuns).
const AbandonGrace = 2 * time.Second

var abandonedRuns atomic.Int64

// AbandonedRuns is the number of script goroutines Run gave up on that are
// still running. The executor claims no new run while it is above zero.
func AbandonedRuns() int { return int(abandonedRuns.Load()) }

const (
	wrapPrefix = "(function (" + returnHookParam + ") { " + returnHookParam +
		"((function (" + returnHookParam + `) {"use strict";`
	wrapSuffix       = "\n})()); })"
	errWrapperBroken = "the script closes the function it runs in (an unbalanced `}`)"
)

// wrapScript makes the script a strict function body (so it may `return`)
// without moving its lines: the prefix sits on the script's first line. The
// program evaluates to an outer function that Run calls with the native
// return hook; the script's function shadows the hook's parameter with its
// own (never passed, so undefined), so the script cannot reach the hook.
func wrapScript(script string) string {
	return wrapPrefix + script + wrapSuffix
}

// wrapperIntact reports that the parsed program is exactly the wrapper with
// the whole script inside the inner function's body. A script with an
// unbalanced `}` that breaks out of the function fails it.
func wrapperIntact(prog *ast.Program, src string) bool {
	fn := wrappedFunction(prog)
	if fn == nil || fn.Body == nil || fn.Async || fn.Generator || paramCount(fn) != 1 {
		return false
	}
	open := file.Idx(strings.Index(src, `{"use strict";`) + 1)
	closing := file.Idx(len(src) - len(wrapSuffix) + 2) // the "}" after the suffix's newline
	return fn.Body.LeftBrace == open && fn.Body.RightBrace == closing
}

func paramCount(fn *ast.FunctionLiteral) int {
	if fn.ParameterList == nil {
		return 0
	}
	return len(fn.ParameterList.List)
}

// wrappedFunction returns F of a program that is exactly
// `(function (hook) { hook((F)()); })`, or nil.
func wrappedFunction(prog *ast.Program) *ast.FunctionLiteral {
	if len(prog.Body) != 1 {
		return nil
	}
	stmt, ok := prog.Body[0].(*ast.ExpressionStatement)
	if !ok {
		return nil
	}
	outerFn, ok := stmt.Expression.(*ast.FunctionLiteral)
	if !ok || outerFn.Body == nil || paramCount(outerFn) != 1 || len(outerFn.Body.List) != 1 {
		return nil
	}
	return hookCallArgument(outerFn.Body.List[0])
}

// hookCallArgument returns F of the statement `hook((F)())`, or nil.
func hookCallArgument(st ast.Statement) *ast.FunctionLiteral {
	stmt, ok := st.(*ast.ExpressionStatement)
	if !ok {
		return nil
	}
	outer, ok := stmt.Expression.(*ast.CallExpression)
	if !ok || len(outer.ArgumentList) != 1 {
		return nil
	}
	if callee, ok := outer.Callee.(*ast.Identifier); !ok || callee.Name.String() != returnHookParam {
		return nil
	}
	inner, ok := outer.ArgumentList[0].(*ast.CallExpression)
	if !ok || len(inner.ArgumentList) != 0 {
		return nil
	}
	fn, _ := inner.Callee.(*ast.FunctionLiteral)
	return fn
}

// scriptShapeError is the ParseRecipe check of the same rule: a script that
// parses but breaks out of the wrapper function. A script that does not
// parse is left to the sandbox, which reports the syntax error.
func scriptShapeError(script string) error {
	src := wrapScript(script)
	prog, err := parser.ParseFile(nil, scriptSrcName, src, 0)
	switch {
	case err != nil:
		return nil //nolint:nilerr // a syntax error is the sandbox's to report, with its line
	case wrapperIntact(prog, src):
		return nil
	default:
		return errors.New(errWrapperBroken)
	}
}

type runResult struct {
	v   goja.Value
	err error
}

// Run executes the script once. It returns the script's return value
// (JSON-decoded), or a *RunInterrupted, a *ScriptError, or an
// ErrSDKPanic/ErrSDKContract error. After an interrupt it returns within
// AbandonGrace even if the script is stuck in a native builtin.
func (s *Sandbox) Run() (any, error) {
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
	results := make(chan runResult, 1)
	go func() { results <- s.execute() }()
	select {
	case r := <-results:
		return s.outcome(r.v, r.err)
	case <-s.stopped:
	}
	grace := time.NewTimer(AbandonGrace)
	defer grace.Stop()
	select {
	case r := <-results:
		return s.outcome(r.v, r.err)
	case <-grace.C:
		return s.abandon(results)
	}
}

// execute runs the program, turning a Go panic that escaped goja into an
// ErrSDKPanic result.
func (s *Sandbox) execute() (r runResult) {
	defer func() {
		if p := recover(); p != nil {
			r = runResult{err: fmt.Errorf("%w: %v", ErrSDKPanic, p)}
		}
	}()
	outer, err := s.rt.RunProgram(s.prog)
	if err != nil {
		return runResult{err: err}
	}
	run, ok := goja.AssertFunction(outer)
	if !ok {
		return runResult{err: fmt.Errorf("%w: the wrapped program is not a function", ErrSDKContract)}
	}
	v, err := run(goja.Undefined(), s.rt.ToValue(s.scriptReturned))
	return runResult{v: v, err: err}
}

// abandon leaves a script goroutine stuck past the grace behind; it counts
// in AbandonedRuns until it ends.
func (s *Sandbox) abandon(results <-chan runResult) (any, error) {
	abandonedRuns.Add(1)
	go func() {
		<-results
		abandonedRuns.Add(-1)
	}()
	s.mu.Lock()
	fatal, reason := s.fatal, s.reason
	s.mu.Unlock()
	if fatal != nil {
		return nil, fatal
	}
	return nil, &RunInterrupted{Reason: reason, Abandoned: true}
}

func (s *Sandbox) outcome(_ goja.Value, runErr error) (any, error) {
	s.mu.Lock()
	fatal, reason, returned := s.fatal, s.reason, s.returned
	s.mu.Unlock()
	if fatal != nil {
		return nil, fatal
	}
	var intr *goja.InterruptedError
	var overflow *goja.StackOverflowError
	var ex *goja.Exception
	switch {
	case runErr == nil && reason != "":
		// Interrupted during the script's last instructions (an SDK call
		// that hit the interrupt returns undefined, and the VM may finish
		// before it checks the flag): the interrupt still decides the run.
		return nil, &RunInterrupted{Reason: reason}
	case runErr == nil:
		return returned, nil
	case errors.As(runErr, &intr):
		return nil, &RunInterrupted{Reason: reason}
	case errors.As(runErr, &overflow):
		return nil, &ScriptError{Name: "RangeError", Message: "maximum call stack size exceeded"}
	case errors.As(runErr, &ex):
		return nil, s.scriptError(ex)
	case errors.Is(runErr, ErrSDKPanic):
		return nil, runErr
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
