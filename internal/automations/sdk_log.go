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
	n := env.Journal.CountKind(StepKindLog)
	capErr := validationf("log() was called more than %d times in this run", MaxLogCalls)
	if n > MaxLogCalls {
		return nil, capErr
	}
	if n == MaxLogCalls {
		return env.Call(StepKindLog, "log", nil, func(*Step) (any, error) { return nil, capErr })
	}
	msg := logMessage(env, rt, call.Arguments)
	return env.Call(StepKindLog, "log", msg, func(*Step) (any, error) { return nil, nil })
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
