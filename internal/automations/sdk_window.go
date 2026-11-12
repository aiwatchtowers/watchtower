package automations

import (
	"encoding/json"
	"fmt"
)

// WindowStateKeyPrefix starts the state keys of the raw window's cursors:
// the SDK writes them (callWindow), a script never does (stateSet).
const WindowStateKeyPrefix = "__window:"

// windowStateKeys maps each window primitive to its cursor's state key.
var windowStateKeys = map[string]string{PrimitiveSlackWindow: WindowStateKeyPrefix + "slack"}

// WindowFloorToday is the one floor a window call may name; the window
// primitives (builtin's slack.window) read it from the call's input.
const WindowFloorToday = "today"

// windowCursorVersion is the cursor value's "v".
const windowCursorVersion = 1

// windowCursor is a window cursor's state value,
// {"v":1,"after_rowid":N,"behind":bool}.
type windowCursor struct {
	V          int   `json:"v"`
	AfterRowID int64 `json:"after_rowid"`
	Behind     bool  `json:"behind"`
}

// WindowCursorOf reads the window cursor at key from an automation's
// committed state (a JSON object; empty or null = {}). A missing key is
// 0, false, nil; a state that is not an object, or a value that is not a
// v1 cursor, is an error.
func WindowCursorOf(state json.RawMessage, key string) (afterRowID int64, behind bool, err error) {
	if len(state) == 0 {
		return 0, false, nil
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(state, &all); err != nil {
		return 0, false, fmt.Errorf("decoding the automation state: %w", err)
	}
	raw, ok := all[key]
	if !ok {
		return 0, false, nil
	}
	return decodeWindowCursor(key, raw)
}

func decodeWindowCursor(key string, raw json.RawMessage) (int64, bool, error) {
	var c windowCursor
	if err := json.Unmarshal(raw, &c); err != nil {
		return 0, false, fmt.Errorf("decoding the window cursor %q: %w", key, err)
	}
	if c.V != windowCursorVersion {
		return 0, false, fmt.Errorf("the window cursor %q has version %d; want %d", key, c.V, windowCursorVersion)
	}
	if c.AfterRowID < 0 {
		return 0, false, fmt.Errorf("the window cursor %q has a negative after_rowid %d", key, c.AfterRowID)
	}
	return c.AfterRowID, c.Behind, nil
}

// windowFloorOf reads a window call's one optional argument: none, {} or
// {floor: "today"}.
func windowFloorOf(name string, raw any) (string, error) {
	if raw == nil {
		return "", nil
	}
	obj, ok := raw.(map[string]any)
	if !ok {
		return "", validationf("%s() takes only {floor}", name)
	}
	for k := range obj {
		if k != "floor" {
			return "", validationf("%s() takes only {floor}", name)
		}
	}
	floor, has := obj["floor"]
	if !has {
		return "", nil
	}
	if floor != WindowFloorToday {
		return "", validationf("%s({floor}): floor must be %q", name, WindowFloorToday)
	}
	return WindowFloorToday, nil
}

// callWindow runs a window primitive (WindowPrimitiveNames) as one tool
// step outside the meter, as callRead does — in a dry run too: the
// permission first, then the argument, then the primitive with the cursor
// the run's buffer holds (the committed state plus this run's sets, so a
// second call reads past the first). A done result stages the next cursor
// in the buffer, committed only with a succeeded run (AUTO-04); a dry run
// never commits. An error, or a status other than done/skipped, fails the
// call as PrimitiveFailed and stages nothing.
//
// The call is not CallBuffered: a resumed run's replay answers it from
// its log without staging the cursor again, so the next run re-reads that
// window (a repeat, never a gap).
func (s *builtinSDK) callWindow(env *Env, name string, raw any, argErr error) (any, error) {
	var floor string
	if argErr == nil {
		floor, argErr = windowFloorOf(name, raw)
	}
	args := map[string]any{}
	if floor != "" {
		args["floor"] = floor
	}
	return env.Call(StepKindTool, name, args, func(step *Step) (any, error) {
		m, err := manifestOf(env)
		if err != nil {
			return nil, err
		}
		entry, err := m.AllowPrimitive(name)
		if err != nil {
			return nil, err
		}
		step.SetPermission(entry)
		if argErr != nil {
			return nil, argErr
		}
		fn := s.b.Primitives[name]
		if fn == nil {
			return nil, notAvailable(name + " is not available")
		}
		if err := env.Buffer.Err(); err != nil {
			return nil, err
		}
		key := windowStateKeys[name]
		var after int64
		if raw, ok := env.Buffer.getRaw(key); ok {
			if after, _, err = decodeWindowCursor(key, raw); err != nil {
				return nil, err
			}
		}
		res, err := fn(env.Ctx, PrimitiveCall{Name: name, BuiltinID: builtinIDOf(env), Trigger: env.Trigger,
			Input: env.Trigger.Builtin, Cursor: after, Floor: floor})
		if err == nil && res.Status != primitiveDone && res.Status != primitiveSkipped {
			err = fmt.Errorf("%s returned status %q (want %q or %q)", name, res.Status, primitiveDone, primitiveSkipped)
		}
		if err != nil {
			return nil, modelCallError(err, ErrNamePrimitiveFailed, "")
		}
		if res.Status == primitiveDone {
			next := windowCursor{V: windowCursorVersion, AfterRowID: res.NextCursor, Behind: res.Behind}
			if err := env.Buffer.Set(key, next); err != nil {
				return nil, err
			}
		}
		return primitiveOutcome(step, res), nil
	})
}
