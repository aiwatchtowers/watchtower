package automations

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/dop251/goja"
)

// LogModule defines log(...args) (spec §4): one step of kind log whose
// args_json is the message — strings as they are, other values as JSON,
// joined by spaces and clipped to MaxLogBytes. A run may log MaxLogCalls
// times; the next call throws ValidationError and is journaled as an error
// step, and calls after it throw without a step, so a script that catches
// the error in a loop cannot flood the journal.
func LogModule() Module {
	return sdkModule{name: "log", fns: map[string]SDKFunc{"log": logCall}}
}

func logCall(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
	if v, err, capped := logCapped(env); capped {
		return v, err
	}
	msg := logMessage(env, rt, call.Arguments)
	// Converting the arguments runs script code (getters, toJSON) that may
	// log itself: check the cap again right before the step begins.
	if v, err, capped := logCapped(env); capped {
		return v, err
	}
	return env.Call(StepKindLog, "log", msg, func(*Step) (any, error) { return nil, nil })
}

// logCapped applies the per-run cap: the call after MaxLogCalls is an error
// step, later ones throw without a step.
func logCapped(env *Env) (any, error, bool) {
	n := env.Journal.CountKind(StepKindLog)
	if n < MaxLogCalls {
		return nil, nil, false
	}
	capErr := validationf("log() was called more than %d times in this run", MaxLogCalls)
	if n > MaxLogCalls {
		return nil, capErr, true
	}
	v, err := env.Call(StepKindLog, "log", nil, func(*Step) (any, error) { return nil, capErr })
	return v, err, true
}

// logMessage renders the arguments like a console line: a value JSON cannot
// represent is shown as JS would print it.
func logMessage(env *Env, rt *goja.Runtime, args []goja.Value) string {
	var b strings.Builder
	for i, a := range args {
		if b.Len() >= MaxLogBytes {
			break
		}
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(logPart(env, rt, a))
	}
	return clipUTF8(b.String(), MaxLogBytes)
}

func logPart(env *Env, rt *goja.Runtime, a goja.Value) string {
	v, err := exportPlain(env.Ctx, rt, a)
	if err != nil {
		if _, isObj := a.(*goja.Object); isObj && !isFunction(a) {
			return fmt.Sprintf("[unloggable value: %v]", err)
		}
		return a.String() // undefined, a symbol, NaN, a BigInt, a function
	}
	if s, ok := v.(string); ok {
		return s
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("[unloggable value: %v]", err)
	}
	return string(raw)
}

func isFunction(v goja.Value) bool {
	_, ok := goja.AssertFunction(v)
	return ok
}
