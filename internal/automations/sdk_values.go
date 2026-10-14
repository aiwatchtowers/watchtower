package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"strconv"

	"github.com/dop251/goja"
)

// maxSDKArgBytes bounds the approximate JSON size of one SDK argument the
// sandbox converts to Go; an SDK result has the same bound
// (MaxSDKResultBytes). Smaller per-call limits (llm input, state, output
// bodies) are checked by the call on top of this one.
const maxSDKArgBytes = MaxSDKResultBytes

// errArgTooLarge is an argument beyond maxSDKArgBytes; each call maps it to
// its own error (StateTooLarge, ResultTooLarge, ValidationError).
var errArgTooLarge = errors.New("the argument is too large")

// errArgUndefined is a top-level undefined argument; each call decides
// whether that means "absent" or is an error.
var errArgUndefined = errors.New("the argument is undefined")

// ctxCheckEvery is how many converted values pass between context checks:
// converting runs native Go, out of the interrupt's reach, so it polls the
// run's context itself.
const ctxCheckEvery = 1024

var bigIntType = reflect.TypeOf((*big.Int)(nil))

// exportPlain converts a script value to a plain Go JSON value (nil, bool,
// int64, float64, string, []any, map[string]any) following JSON.stringify
// where it keeps data — toJSON is applied, undefined drops an object key and
// is null in an array — and refusing (ValidationError) what JSON cannot
// represent: functions, symbols, BigInts, NaN and ±Infinity, cycles, nesting
// deeper than MaxJSONDepth. A top-level undefined returns errArgUndefined,
// an argument beyond maxSDKArgBytes errArgTooLarge. Getters and toJSON run
// script code, which stays interruptible.
func exportPlain(ctx context.Context, rt *goja.Runtime, v goja.Value) (any, error) {
	c := &plainConverter{ctx: ctx, rt: rt, left: maxSDKArgBytes}
	out, undefined, err := c.convert("", v, 0, true)
	if err != nil {
		return nil, err
	}
	if undefined {
		return nil, errArgUndefined
	}
	return out, nil
}

type plainConverter struct {
	ctx   context.Context
	rt    *goja.Runtime
	left  int
	nodes int
	stack []*goja.Object // the objects being converted, for cycle detection
}

func notJSON(what string) error {
	return &SDKError{Name: ErrNameValidation, Message: what + " is not a JSON value"}
}

func (c *plainConverter) spend(n int) error {
	c.left -= n
	if c.left < 0 {
		return errArgTooLarge
	}
	return nil
}

func (c *plainConverter) tick() error {
	c.nodes++
	if c.nodes%ctxCheckEvery == 0 {
		return c.ctx.Err()
	}
	return nil
}

// convert converts v (found under key); undefined reports a value JSON would
// leave out. applyToJSON is false for the value a toJSON call returned.
func (c *plainConverter) convert(key string, v goja.Value, depth int, applyToJSON bool) (out any, undefined bool, err error) {
	if err := c.tick(); err != nil {
		return nil, false, err
	}
	if depth > MaxJSONDepth {
		return nil, false, &SDKError{Name: ErrNameValidation,
			Message: fmt.Sprintf("the value is nested deeper than %d levels", MaxJSONDepth)}
	}
	switch {
	case v == nil || goja.IsUndefined(v):
		return nil, true, nil
	case goja.IsNull(v):
		return nil, false, c.spend(4)
	}
	if _, ok := v.(*goja.Symbol); ok {
		return nil, false, notJSON("a symbol")
	}
	obj, ok := v.(*goja.Object)
	if !ok {
		out, err := c.primitive(v.Export())
		return out, false, err
	}
	if _, fn := goja.AssertFunction(obj); fn {
		return nil, false, notJSON("a function")
	}
	if applyToJSON {
		if toJSON, ok := goja.AssertFunction(obj.Get("toJSON")); ok {
			r, err := toJSON(obj, c.rt.ToValue(key))
			if err != nil {
				return nil, false, err
			}
			return c.convert(key, r, depth, false)
		}
	}
	out, err = c.object(obj, depth)
	return out, false, err
}

func (c *plainConverter) primitive(e any) (any, error) {
	switch x := e.(type) {
	case nil:
		return nil, c.spend(4)
	case bool:
		return x, c.spend(5)
	case string:
		return x, c.spend(len(x) + 2)
	case int64:
		return x, c.spend(8)
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return nil, notJSON(strconv.FormatFloat(x, 'g', -1, 64))
		}
		return x, c.spend(8)
	case *big.Int:
		return nil, notJSON("a BigInt")
	}
	return nil, notJSON(fmt.Sprintf("a %T", e))
}

func (c *plainConverter) object(obj *goja.Object, depth int) (any, error) {
	switch obj.ClassName() {
	case "Number", "Boolean":
		return c.primitive(obj.Export())
	case "String":
		return c.primitive(obj.String())
	case "Array":
		return c.nested(obj, depth, c.array)
	}
	if obj.ExportType() == bigIntType {
		return nil, notJSON("a BigInt")
	}
	return c.nested(obj, depth, c.fields)
}

// nested converts a container with cycle detection.
func (c *plainConverter) nested(obj *goja.Object, depth int, conv func(*goja.Object, int) (any, error)) (any, error) {
	for _, o := range c.stack {
		if o == obj {
			return nil, &SDKError{Name: ErrNameValidation, Message: "the value is cyclic and is not a JSON value"}
		}
	}
	c.stack = append(c.stack, obj)
	defer func() { c.stack = c.stack[:len(c.stack)-1] }()
	return conv(obj, depth)
}

func (c *plainConverter) array(obj *goja.Object, depth int) (any, error) {
	n := obj.Get("length").ToInteger()
	if n > int64(c.left) { // every element costs at least a byte
		return nil, errArgTooLarge
	}
	out := make([]any, 0, n)
	for i := range n {
		el, _, err := c.convert(strconv.FormatInt(i, 10), obj.Get(strconv.FormatInt(i, 10)), depth+1, true)
		if err != nil {
			return nil, err
		}
		if err := c.spend(1); err != nil {
			return nil, err
		}
		out = append(out, el) // undefined is null in an array
	}
	return out, nil
}

func (c *plainConverter) fields(obj *goja.Object, depth int) (any, error) {
	out := map[string]any{}
	for _, k := range obj.Keys() {
		el, undefined, err := c.convert(k, obj.Get(k), depth+1, true)
		if err != nil {
			return nil, err
		}
		if undefined {
			continue
		}
		if err := c.spend(len(k) + 3); err != nil {
			return nil, err
		}
		out[k] = el
	}
	return out, nil
}

// argAt converts argument i; a missing or undefined argument is (nil,
// false).
func argAt(env *Env, rt *goja.Runtime, call goja.FunctionCall, i int) (any, bool, error) {
	v, err := exportPlain(env.Ctx, rt, call.Argument(i))
	if errors.Is(err, errArgUndefined) {
		return nil, false, nil
	}
	return v, err == nil, err
}

// tooLargeAs maps errArgTooLarge to the call's own error and passes other
// errors through.
func tooLargeAs(err error, name, msg string) error {
	if errors.Is(err, errArgTooLarge) {
		return &SDKError{Name: name, Message: msg}
	}
	return err
}

// jsonValue keeps a decoded JSON null a null for the script: a nil result
// would reach it as undefined.
func jsonValue(v any) any {
	if v == nil {
		return json.RawMessage("null")
	}
	return v
}

// validationf is a ValidationError with a formatted message.
func validationf(format string, a ...any) error {
	return &SDKError{Name: ErrNameValidation, Message: fmt.Sprintf(format, a...)}
}
