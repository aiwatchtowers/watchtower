package automations

import (
	"fmt"
	"maps"
	"slices"
	"unicode/utf8"

	"github.com/dop251/goja"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// OutputMod is the output module: one output.<kind> path per registered
// kind. P1 registers inbox and report; later phases register further kinds
// (briefing, target, slack) on the same *OutputMod before it is installed.
// It also defines output.remove (living artifacts) and carries the
// output.inbox field hooks (RegisterInboxField).
type OutputMod struct {
	kinds       map[string]SDKFunc
	inboxFields map[string]InboxFieldFunc
}

// InboxFieldFunc handles one output.inbox field a later sub-project owns
// (RegisterInboxField): fn is the call's name, v the field's raw
// goja-exported value and o the output being built, which the hook may
// change. Its error is thrown into the script and nothing is buffered.
type InboxFieldFunc func(env *Env, fn string, v any, o *db.AutomationOutput) error

// The output kinds P1 registers (automation_outputs.kind).
const (
	outputKindInbox  = "inbox"
	outputKindReport = "report"
)

// OutputModule returns the output module with output.inbox and
// output.report registered.
func OutputModule() *OutputMod {
	m := &OutputMod{kinds: map[string]SDKFunc{}, inboxFields: map[string]InboxFieldFunc{}}
	m.RegisterOutputKind(outputKindInbox, bufferedOutput(outputKindInbox,
		outputOpts{priority: true, card: true, blocks: true, key: true, hooks: m.inboxFields}))
	m.RegisterOutputKind(outputKindReport, bufferedOutput(outputKindReport, outputOpts{}))
	m.kinds[outputRemove] = removeOutput
	return m
}

// RegisterInboxField hands output.inbox's field name to fn (sub-project B's
// folder). A field output.inbox owns cannot be registered (a programming
// error: it panics). A field no hook takes stays an unknown field, except
// folder, which is reserved for its hook.
func (m *OutputMod) RegisterInboxField(name string, fn InboxFieldFunc) {
	if slices.Contains(inboxOwnFields, name) {
		panic(fmt.Sprintf("automations: output.inbox owns the field %q", name))
	}
	m.inboxFields[name] = fn
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

// inboxOwnFields are the fields output.inbox validates itself.
var inboxOwnFields = []string{"title", "body", "priority", "link", "actions", "blocks", "key"}

// inboxFolderField is reserved for sub-project B's hook: refused with its
// own message until the hook is registered.
const inboxFolderField = "folder"

// outputOpts are the optional fields an output kind takes: priority, the
// Inbox card's link and actions (card), its block document (blocks), a
// living artifact's key (key), and the fields registered hooks take.
type outputOpts struct {
	priority, card, blocks, key bool
	hooks                       map[string]InboxFieldFunc
}

// bufferedOutput is output.<kind>({title, body, priority?, link?, actions?})
// for a kind the commit buffer holds until the run succeeds (spec §5);
// opts names the optional fields the kind takes. outputs: [<kind>] gates
// it; a Reply action also needs inbox:reply. The body is capped at
// MaxOutputBodyBytes. In a dry run the output is buffered (it is what the
// dry run would have written), the step is dry_run and the call returns
// {status:"dry_run"}. A resumed run's replay runs it again (CallBuffered),
// so the rebuilt buffer carries the same card.
func bufferedOutput(kind string, opts outputOpts) SDKFunc {
	return func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		fn := "output." + kind
		arg, _, argErr := argAt(env, rt, call, 0)
		return env.CallBuffered(StepKindOutput, kind, arg, func(step *Step) (any, error) {
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
			o, err := outputRow(env, fn, kind, arg, opts)
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

// outputRow validates {title, body | blocks, key?, priority?, link?,
// actions?, <hook fields>} into a buffered output. An inbox card (opts.card)
// gets its content hash.
func outputRow(env *Env, fn, kind string, arg any, opts outputOpts) (db.AutomationOutput, error) {
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
	if err := checkOutputFields(fn, fields, opts); err != nil {
		return o, err
	}
	if o.Title, ok = fields["title"].(string); !ok || o.Title == "" {
		return o, validationf("%s(): title must be a non-empty string", fn)
	}
	if n := utf8.RuneCountInString(o.Title); n > MaxOutputTitleChars {
		return o, validationf("%s(): the title is %d characters; the limit is %d", fn, n, MaxOutputTitleChars)
	}
	_, hasBlocks := fields["blocks"]
	if _, hasBody := fields["body"]; hasBody && hasBlocks {
		return o, validationf("%s(): pass body or blocks, not both", fn)
	}
	if !hasBlocks {
		if o.Body, ok = fields["body"].(string); !ok {
			return o, validationf("%s(): body must be a string", fn)
		}
	}
	if p, has := fields["priority"]; has {
		o.Priority, ok = p.(string)
		if !ok || !slices.Contains(outputPriorities, o.Priority) {
			return o, validationf("%s(): priority must be one of high, medium, low", fn)
		}
	}
	if opts.key {
		var err error
		if o.OutputKey, err = outputKey(env, fn, fields); err != nil {
			return o, err
		}
	}
	if opts.card {
		var err error
		if o.Link, o.Actions, err = inboxCard(env, fn, fields); err != nil {
			return o, err
		}
	}
	var doc *blocks.Document
	if hasBlocks {
		d, err := blocks.Validate(fn, fields["blocks"], blocks.Options{
			BuiltIn: isBuiltinRun(env), AllowKind: allowActionKind(env, fn), CardActions: len(o.Actions),
		})
		if err != nil {
			return o, blockError(err)
		}
		canonical, err := d.Canonical()
		if err != nil {
			return o, fmt.Errorf("%s(): encoding blocks: %w", fn, err) // unreachable: Validate encoded it
		}
		doc, o.BlocksJSON, o.Body = &d, string(canonical), blocks.PlainText(d, MaxOutputBodyBytes)
	}
	for _, name := range slices.Sorted(maps.Keys(opts.hooks)) {
		if v, has := fields[name]; has {
			if err := opts.hooks[name](env, fn, v, &o); err != nil {
				return o, err
			}
		}
	}
	if opts.card {
		o.ContentHash = blocks.ContentHash(o.Title, o.Body, doc, o.Priority, o.Link, o.Actions)
	}
	return o, nil
}

// checkOutputFields refuses a field output.<kind> does not take. folder is
// reserved for its hook (sub-project B) on a kind that takes hook fields.
func checkOutputFields(fn string, fields map[string]any, opts outputOpts) error {
	allowed := []string{"title", "body"}
	if opts.priority {
		allowed = append(allowed, "priority")
	}
	if opts.card {
		allowed = append(allowed, "link", "actions")
	}
	if opts.blocks {
		allowed = append(allowed, "blocks")
	}
	if opts.key {
		allowed = append(allowed, "key")
	}
	for k := range fields {
		if slices.Contains(allowed, k) {
			continue
		}
		if _, hooked := opts.hooks[k]; hooked {
			continue
		}
		if k == inboxFolderField && opts.hooks != nil {
			return validationf("%s(): folder is not available yet", fn)
		}
		return validationf("%s(): unknown field %q", fn, k)
	}
	return nil
}

// isBuiltinRun reports a built-in automation's run (origin builtin), whose
// cards may carry action and reminder refs.
func isBuiltinRun(env *Env) bool {
	if env.Automation != nil {
		return env.Automation.IsBuiltin()
	}
	return env.Recipe != nil && env.Recipe.Scope.IsBuiltin()
}

// keepsLivingArtifacts reports a recipe that keeps living artifacts.
func keepsLivingArtifacts(env *Env) bool {
	return env.Recipe != nil && env.Recipe.Artifacts == ArtifactsLiving
}
