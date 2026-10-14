package automations

import (
	"fmt"
	"maps"
	"slices"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/db"
)

// OutputMod is the output module: one output.<kind> path per registered
// kind. P1 registers inbox and report; later phases register further kinds
// (briefing, target, slack) on the same *OutputMod before it is installed.
type OutputMod struct {
	kinds map[string]SDKFunc
}

// The output kinds P1 registers (automation_outputs.kind).
const (
	outputKindInbox  = "inbox"
	outputKindReport = "report"
)

// OutputModule returns the output module with output.inbox and
// output.report registered.
func OutputModule() *OutputMod {
	m := &OutputMod{kinds: map[string]SDKFunc{}}
	m.RegisterOutputKind(outputKindInbox, bufferedOutput(outputKindInbox, true))
	m.RegisterOutputKind(outputKindReport, bufferedOutput(outputKindReport, false))
	return m
}

// RegisterOutputKind defines output.<kind> as fn (a later registration of
// the same kind replaces the earlier one).
func (m *OutputMod) RegisterOutputKind(kind string, fn SDKFunc) { m.kinds[kind] = fn }

// Name is "output".
func (m *OutputMod) Name() string { return "output" }

// Install defines output.<kind> for every registered kind.
func (m *OutputMod) Install(def Definer) {
	for _, k := range slices.Sorted(maps.Keys(m.kinds)) {
		def.Define("output."+k, m.kinds[k])
	}
}

var outputPriorities = []string{"high", "medium", "low"}

// bufferedOutput is output.<kind>({title, body, priority?}) for a kind the
// commit buffer holds until the run succeeds (spec §5). outputs: [<kind>]
// gates it; the body is capped at MaxOutputBodyBytes. In a dry run the
// output is buffered (it is what the dry run would have written), the step
// is dry_run and the call returns {status:"dry_run"}.
func bufferedOutput(kind string, withPriority bool) SDKFunc {
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
			if argErr != nil {
				return nil, tooLargeAs(argErr, ErrNameResultTooLarge,
					fmt.Sprintf("%s(): the argument is larger than %d bytes; a body may be at most %d bytes",
						fn, maxSDKArgBytes, MaxOutputBodyBytes))
			}
			o, err := outputRow(env, fn, kind, arg, withPriority)
			if err != nil {
				return nil, err
			}
			if err := env.Buffer.AddOutput(o); err != nil {
				return nil, err
			}
			if env.DryRun {
				return dryRunResult(step, arg), nil
			}
			return nil, nil
		})
	}
}

// outputRow validates {title, body, priority?} into a buffered output.
func outputRow(env *Env, fn, kind string, arg any, withPriority bool) (db.AutomationOutput, error) {
	o := db.AutomationOutput{Kind: kind}
	if env.Automation != nil {
		o.AutomationID = env.Automation.ID
	}
	if env.Run != nil {
		o.RunID = env.Run.ID
	}
	fields, ok := arg.(map[string]any)
	if !ok {
		return o, validationf("%s() takes an object {title, body}", fn)
	}
	if err := checkOutputFields(fn, fields, withPriority); err != nil {
		return o, err
	}
	if o.Title, ok = fields["title"].(string); !ok || o.Title == "" {
		return o, validationf("%s(): title must be a non-empty string", fn)
	}
	if n := utf8.RuneCountInString(o.Title); n > MaxOutputTitleChars {
		return o, validationf("%s(): the title is %d characters; the limit is %d", fn, n, MaxOutputTitleChars)
	}
	if o.Body, ok = fields["body"].(string); !ok {
		return o, validationf("%s(): body must be a string", fn)
	}
	if p, has := fields["priority"]; has {
		o.Priority, ok = p.(string)
		if !ok || !slices.Contains(outputPriorities, o.Priority) {
			return o, validationf("%s(): priority must be one of high, medium, low", fn)
		}
	}
	return o, nil
}

// checkOutputFields refuses a field output.<kind> does not take.
func checkOutputFields(fn string, fields map[string]any, withPriority bool) error {
	allowed := []string{"title", "body"}
	if withPriority {
		allowed = append(allowed, "priority")
	}
	for k := range fields {
		if !slices.Contains(allowed, k) {
			return validationf("%s(): unknown field %q", fn, k)
		}
	}
	return nil
}
