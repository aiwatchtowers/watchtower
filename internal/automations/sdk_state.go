package automations

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/dop251/goja"
)

// StateModule defines state.get(key), state.set(key, value) and state.all()
// over the run's CommitBuffer (spec §5): reads see the committed state plus
// this run's own sets; sets are committed only with a succeeded run. A value
// JSON cannot represent is a ValidationError at the set call and nothing is
// buffered. In a dry run state.set returns {status:"dry_run"} and its step
// is dry_run (the value is still buffered, so later gets see it; a dry run
// never commits).
func StateModule() Module {
	return sdkModule{name: "state", fns: map[string]SDKFunc{
		"state.get": stateGet,
		"state.set": stateSet,
		"state.all": stateAll,
	}}
}

func stateKey(env *Env, rt *goja.Runtime, call goja.FunctionCall, fn string) (string, error) {
	v, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return "", err
	}
	key, ok := v.(string)
	if !ok || key == "" {
		return "", validationf("%s(key): key must be a non-empty string", fn)
	}
	return key, nil
}

func stateGet(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
	key, keyErr := stateKey(env, rt, call, "state.get")
	return env.Call(StepKindState, "get", map[string]any{"key": key}, func(*Step) (any, error) {
		if keyErr != nil {
			return nil, keyErr
		}
		v, ok := env.Buffer.Get(key)
		switch {
		case !ok:
			return nil, nil // undefined
		case v == nil:
			return json.RawMessage("null"), nil
		}
		return v, nil
	})
}

func stateSet(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
	key, keyErr := stateKey(env, rt, call, "state.set")
	value, valueErr := exportPlain(env.Ctx, rt, call.Argument(1))
	args := map[string]any{"key": key}
	if valueErr == nil {
		args["value"] = value
	}
	return env.Call(StepKindState, "set", args, func(step *Step) (any, error) {
		switch {
		case keyErr != nil:
			return nil, keyErr
		case errors.Is(valueErr, errArgUndefined):
			return nil, validationf("state.set(%q): undefined is not a JSON value", key)
		case valueErr != nil:
			return nil, tooLargeAs(valueErr, ErrNameStateTooLarge,
				fmt.Sprintf("state.set(%q): the value is larger than the %d-byte state limit", key, MaxStateBytes))
		}
		if err := env.Buffer.Set(key, value); err != nil {
			return nil, err
		}
		if env.DryRun {
			return dryRunResult(step, args), nil
		}
		return nil, nil
	})
}

func stateAll(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
	return env.Call(StepKindState, "all", nil, func(*Step) (any, error) {
		return env.Buffer.All(), nil
	})
}
