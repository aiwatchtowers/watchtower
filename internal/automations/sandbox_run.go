package automations

import (
	"errors"
	"fmt"
	"math/big"
	"reflect"
	"runtime/metrics"
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
	case !wrapperIntact(prog, src):
		return errors.New(errWrapperBroken)
	default:
		return bigIntRefusal(prog)
	}
}

// execHelper is the global the compiler routes direct `x.exec(…)` and
// `x["exec"](…)` calls through (rewriteExecCalls): goja reports a regexp2
// match that timed out as "no match", and RegExp.prototype.exec itself is
// left alone (replacing it takes every RegExp method off goja's fast path),
// so the helper times the call instead. A script may not use the name.
const execHelper = "$__automationExec"

// bigIntRefusal refuses a program holding a BigInt literal (BigInt is not
// available in automations, owner decision ask #331: its ** and <<
// operators build a result of any size in one native step) or naming
// execHelper. It walks the parsed program, so nothing can hide where a
// lexical scan would miss it. Line is the script's own 1-based line (the
// wrapper prefix sits on the script's first line).
func bigIntRefusal(prog *ast.Program) error {
	var refusal *PreParseError
	walkAST(reflect.ValueOf(prog), func(node any) bool {
		switch n := node.(type) {
		case *ast.NumberLiteral:
			if _, isBig := n.Value.(*big.Int); isBig {
				refusal = &PreParseError{Word: n.Literal, Line: programLine(prog, n.Idx), BigInt: true}
			}
		case *ast.Identifier:
			if n.Name == execHelper {
				refusal = &PreParseError{Word: execHelper, Line: programLine(prog, n.Idx), Reserved: true}
			}
		}
		return refusal == nil
	})
	if refusal == nil {
		return nil
	}
	return refusal
}

func programLine(prog *ast.Program, idx file.Idx) int {
	if prog.File == nil {
		return 0
	}
	return prog.File.Position(int(idx) - prog.File.Base()).Line
}

// rewriteExecCalls turns `x.exec(a…)` and `x["exec"](a…)` into
// `$__automationExec(x, a…)`. An aliased exec (`var f = re.exec; f.call(re,
// s)`) or an optional call (`re.exec?.(s)`) is not rewritten.
func rewriteExecCalls(prog *ast.Program) {
	walkAST(reflect.ValueOf(prog), func(node any) bool {
		call, ok := node.(*ast.CallExpression)
		if !ok {
			return true
		}
		var target ast.Expression
		switch c := call.Callee.(type) {
		case *ast.DotExpression:
			if c.Identifier.Name == "exec" {
				target = c.Left
			}
		case *ast.BracketExpression:
			if lit, ok := c.Member.(*ast.StringLiteral); ok && lit.Value == "exec" {
				target = c.Left
			}
		}
		if target != nil {
			call.Callee = &ast.Identifier{Name: execHelper, Idx: call.Callee.Idx0()}
			call.ArgumentList = append([]ast.Expression{target}, call.ArgumentList...)
		}
		return true
	})
}

// walkAST calls visit on every node of an AST value (pointers, interfaces,
// structs, slices), parents before children, until visit returns false; it
// reports whether the walk ran to the end.
func walkAST(v reflect.Value, visit func(node any) bool) bool {
	switch v.Kind() {
	case reflect.Pointer, reflect.Interface:
		if v.IsNil() {
			return true
		}
		if _, ok := v.Interface().(*file.File); ok {
			return true // source text and line tables, no nodes
		}
		if v.Kind() == reflect.Pointer && !visit(v.Interface()) {
			return false
		}
		return walkAST(v.Elem(), visit)
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if v.Type().Field(i).IsExported() && !walkAST(v.Field(i), visit) {
				return false
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			if !walkAST(v.Index(i), visit) {
				return false
			}
		}
	default: // scalars, strings and maps hold no AST nodes
	}
	return true
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
	runEvents.Add(1)
	defer runEvents.Add(1)
	done, watched, heapWatched := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		s.watchDeadline(done)
	}()
	go func() {
		defer close(heapWatched)
		s.watchHeap(done)
	}()
	defer func() {
		close(done)
		<-watched
		<-heapWatched
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
	var se *ScriptError
	switch {
	case errors.As(fatal, &se) && se.Message == errTooMuchMemory().Message:
		// stopped for memory, then stuck in a native call: a runaway
		return nil, &RunInterrupted{Reason: InterruptMemory, Abandoned: true}
	case fatal != nil:
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

// RunHeapBudget is how far the Go heap's live bytes may grow above a run's
// baseline before the run is stopped ("the automation used too much
// memory"). goja has no heap limit and many builtins allocate in proportion
// to their input; the per-builtin caps stop single huge calls, this stops
// everything else (a string doubled in a loop, many mid-sized calls).
//
// The heap is the whole daemon's, so the baseline moves up to the current
// live bytes whenever the run resumes from a wait or another run starts or
// ends, and nothing is sampled while the run waits: another run's growth is
// not charged to this one. The reading is the live heap as of the last GC
// (/gc/heap/live:bytes, garbage never counts), sampled every
// heapPollInterval, so a run is stopped at the first GC after it passed the
// budget: the overshoot is what it allocated since that GC (at most about
// the heap's size then, GOGC=100) plus one native step still running.
var RunHeapBudget uint64 = 1 << 30

// heapPollInterval is how often watchHeap samples the heap.
const heapPollInterval = 10 * time.Millisecond

// runEvents counts sandbox runs starting and ending: a change re-baselines
// every running watchHeap.
var runEvents atomic.Int64

// errTooMuchMemory ends a run whose heap growth passed RunHeapBudget.
func errTooMuchMemory() *ScriptError {
	return &ScriptError{Name: "RangeError",
		Message: fmt.Sprintf("the automation used too much memory (more than %d MiB)", RunHeapBudget>>20)}
}

func liveHeap() uint64 {
	sample := []metrics.Sample{{Name: "/gc/heap/live:bytes"}}
	metrics.Read(sample)
	return sample[0].Value.Uint64()
}

// watchHeap stops the run (uncatchably, like an interrupt: the memory must
// be released) on the first sample whose live heap passed the baseline plus
// RunHeapBudget (see RunHeapBudget for when the baseline moves).
func (s *Sandbox) watchHeap(done <-chan struct{}) {
	m := s.env.Meter
	base, events, paused := liveHeap(), runEvents.Load(), false
	tick := time.NewTicker(heapPollInterval)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
		}
		if m.Paused() {
			paused = true
			continue
		}
		live := liveHeap()
		if e := runEvents.Load(); paused || e != events {
			paused, events, base = false, e, max(base, live)
		}
		if live > base+RunHeapBudget {
			s.abort(errTooMuchMemory())
			return
		}
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
