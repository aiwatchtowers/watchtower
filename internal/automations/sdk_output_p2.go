package automations

import (
	"encoding/json"
	"fmt"

	"github.com/dop251/goja"
)

// The output kinds P2 registers (spec §5).
const (
	outputKindBriefing = "briefing"
	outputKindTarget   = "target"
	outputKindSlack    = "slack"
)

// registerP2OutputKinds adds output.briefing, output.target and output.slack
// to m, closing over b for the two registry shortcuts.
func registerP2OutputKinds(m *OutputMod, b Backends) {
	m.RegisterOutputKind(outputKindBriefing, bufferedOutput(outputKindBriefing, false))
	for tool, kind := range outputTools {
		m.RegisterOutputKind(kind, toolOutput(b, kind, tool))
	}
}

// toolOutput is output.<kind>(args) for a kind that is sugar for a registry
// write (spec §5): outputs: [<kind>] is the gate (the manifest needs no
// tool:<tool> entry), then the call takes tool()'s write path — dry run,
// default reason, Registry.Propose with the run's binding — so trust and an
// auto grant on <tool> apply as to a tool() write. It takes exactly one
// argument and never waits.
func toolOutput(b Backends, kind, tool string) SDKFunc {
	return func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		fn := "output." + kind
		arg, _, argErr := argAt(env, rt, call, 0)
		return env.Call(StepKindOutput, kind, arg, func(step *Step) (any, error) {
			m, err := manifestOf(env)
			if err != nil {
				return nil, err
			}
			entry, err := m.AllowOutput(kind)
			if err != nil {
				return nil, err
			}
			step.SetPermission(entry)
			args, err := toolOutputArgs(fn, arg, argErr, len(call.Arguments))
			if err != nil {
				return nil, err
			}
			if b.Registry == nil {
				return nil, notAvailable("no tool registry is configured")
			}
			t, ok := b.Registry.Get(tool)
			if !ok {
				return nil, notAvailable(fn + "(): the " + tool + " tool is not available")
			}
			return writeTool(env, b, step, t, args, false)
		})
	}
}

// toolOutputArgs validates the one object argument of a registry-backed
// output and encodes it for the registry.
func toolOutputArgs(fn string, arg any, argErr error, nArgs int) (json.RawMessage, error) {
	if argErr != nil {
		return nil, tooLargeAs(argErr, ErrNameValidation,
			fmt.Sprintf("%s(): the argument is larger than %d bytes", fn, maxSDKArgBytes))
	}
	if nArgs > 1 {
		return nil, validationf("%s() takes one argument and never waits; use tool() with {wait: true} to wait", fn)
	}
	fields, ok := arg.(map[string]any)
	if !ok {
		return nil, validationf("%s() takes an object of the tool's arguments", fn)
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		return nil, validationf("%s(): %v", fn, err)
	}
	return raw, nil
}
