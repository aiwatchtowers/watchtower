package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/db"
)

// BuiltinInput is a slot run's manual input (event_json {"builtin": BuiltinInput}).
// The fields below are the whole list.
type BuiltinInput struct {
	Only     []string `json:"only,omitempty"`     // primitive names to run; empty = all
	Date     string   `json:"date,omitempty"`     // YYYY-MM-DD; "" = today (local)
	Feedback string   `json:"feedback,omitempty"` // plan.compose only
	Force    bool     `json:"force,omitempty"`    // plan.compose only
	// Since is Run Now's Scan from, an RFC 3339 instant normalised to UTC at
	// decode (track.scan only). A script never passes it: track.scan takes
	// it from here.
	Since string `json:"since,omitempty"`
}

// PrimitiveCall is one primitive call (brief.compose, plan.compose) as its
// Go implementation gets it.
type PrimitiveCall struct {
	Name      string         // "brief.compose"
	BuiltinID string         // the built-in whose recipe made the call
	Prompt    string         // the recipe's prompt text
	Args      map[string]any // the call's other arguments, as the script passed them
	Trigger   TriggerInfo    // Kind "sync" | "manual"
	Input     BuiltinInput
	Role      string // the owner profile's role, resolved once per run
}

// PrimitiveUsage is what one primitive call spent on its model calls. A
// primitive must report its real usage: the meter debits exactly what it
// reports (no estimate is made), so unreported tokens escape the run's
// budget. Reported: the provider reported CostUSD.
type PrimitiveUsage struct {
	InputTokens, OutputTokens int
	CostUSD                   float64
	Reported                  bool
}

// PrimitiveResult is what a primitive returns.
type PrimitiveResult struct {
	Status string         // "done" | "skipped"
	Fields map[string]any // returned to the script next to status (e.g. briefing_id)
	Note   string         // journalled on the step (e.g. the placeholder fallback)
	Usage  PrimitiveUsage
}

// The statuses a primitive may return.
const (
	primitiveDone    = "done"
	primitiveSkipped = "skipped"
)

// PrimitiveFunc implements one primitive (Backends.Primitives).
type PrimitiveFunc func(ctx context.Context, call PrimitiveCall) (PrimitiveResult, error)

// builtinPayload is a slot run's event_json.
type builtinPayload struct {
	Builtin BuiltinInput `json:"builtin"`
}

// builtinInputOf decodes a slot run's event_json ("" = no input). A date
// that is not YYYY-MM-DD, a since that is not an RFC 3339 instant, or an
// only entry that is not a primitive (ValidationError), is refused.
func builtinInputOf(eventJSON string) (BuiltinInput, error) {
	if eventJSON == "" {
		return BuiltinInput{}, nil
	}
	var p builtinPayload
	if err := json.Unmarshal([]byte(eventJSON), &p); err != nil {
		return BuiltinInput{}, fmt.Errorf("decoding the run's built-in input: %w", err)
	}
	for _, name := range p.Builtin.Only {
		if !slices.Contains(BuiltinPrimitiveNames, name) {
			return BuiltinInput{}, validationf("the run's built-in input: only names an unknown primitive %q", name)
		}
	}
	if d := p.Builtin.Date; d != "" {
		if _, err := time.Parse(time.DateOnly, d); err != nil {
			return BuiltinInput{}, fmt.Errorf("decoding the run's built-in input: date %q is not YYYY-MM-DD", d)
		}
	}
	if since := p.Builtin.Since; since != "" {
		at, err := time.Parse(time.RFC3339, since)
		if err != nil {
			return BuiltinInput{}, fmt.Errorf("decoding the run's built-in input: since %q is not an RFC 3339 instant", since)
		}
		p.Builtin.Since = at.UTC().Format(time.RFC3339Nano) // the primitive always gets UTC
	}
	return p.Builtin, nil
}

// primitiveTrackScan is the watch recipes' primitive (capability
// track:scan, PrimitiveCapability), the one primitive outside
// BuiltinPrimitiveNames.
const primitiveTrackScan = "track.scan"

// sdkPrimitiveNames are the primitives the SDK may define: the built-ins'
// and track.scan.
var sdkPrimitiveNames = append(slices.Clone(BuiltinPrimitiveNames), primitiveTrackScan)

// primitivePromptKey is the argument that carries a primitive's prompt text
// when it is not "prompt" (track.scan's instruction); it reaches the
// primitive as PrimitiveCall.Prompt.
var primitivePromptKey = map[string]string{primitiveTrackScan: "instruction"}

func promptKeyOf(name string) string {
	if k, ok := primitivePromptKey[name]; ok {
		return k
	}
	return "prompt"
}

// primitiveExtraArgs are the optional argument keys a primitive takes
// besides its prompt, each with its check (which returns the value the
// primitive gets); they reach it as PrimitiveCall.Args. A script never
// passes track.scan's since: Go takes it from the run's input.
var primitiveExtraArgs = map[string]map[string]func(v any) (any, error){
	primitiveTrackScan: {"extra": trackScanExtra},
}

// TrackScanItem is one item of track.scan's extra argument, which reaches
// the primitive as PrimitiveCall.Args["extra"] ([]TrackScanItem).
type TrackScanItem struct {
	SourceType string `json:"source_type"` // TrackScanSourceTypes
	SourceID   string `json:"source_id"`
	Text       string `json:"text"` // ≤ MaxTrackScanItemText bytes
	At         string `json:"at"`   // RFC 3339
}

// track.scan's extra limits.
const (
	MaxTrackScanExtra    = 40
	MaxTrackScanItemText = 4 << 10
)

// TrackScanSourceTypes are the source types a track.scan extra item may name.
var TrackScanSourceTypes = []string{"slack", "email", "jira", "linear"}

// trackScanExtra checks track.scan's extra: an array of at most
// MaxTrackScanExtra objects {source_type, source_id, text, at}.
func trackScanExtra(v any) (any, error) {
	arr, ok := v.([]any)
	if !ok {
		return nil, validationf("track.scan(): extra must be an array")
	}
	if len(arr) > MaxTrackScanExtra {
		return nil, validationf("track.scan(): extra holds %d items; at most %d", len(arr), MaxTrackScanExtra)
	}
	items := make([]TrackScanItem, 0, len(arr))
	for i, raw := range arr {
		it, err := trackScanItem(raw)
		if err != nil {
			return nil, validationf("track.scan(): extra[%d]: %s", i, err)
		}
		items = append(items, it)
	}
	return items, nil
}

func trackScanItem(raw any) (TrackScanItem, error) {
	var it TrackScanItem
	obj, ok := raw.(map[string]any)
	if !ok {
		return it, errors.New("an item must be an object {source_type, source_id, text, at}")
	}
	fields := map[string]*string{"source_type": &it.SourceType, "source_id": &it.SourceID, "text": &it.Text, "at": &it.At}
	for _, k := range slices.Sorted(maps.Keys(obj)) {
		v := obj[k]
		dst, ok := fields[k]
		if !ok {
			return it, fmt.Errorf("unknown key %q", k)
		}
		if *dst, ok = v.(string); !ok {
			return it, fmt.Errorf("%s must be a string", k)
		}
	}
	switch {
	case !slices.Contains(TrackScanSourceTypes, it.SourceType):
		return it, fmt.Errorf("source_type %q is not one of %s", it.SourceType, strings.Join(TrackScanSourceTypes, ", "))
	case strings.TrimSpace(it.SourceID) == "":
		return it, errors.New("source_id must be a non-empty string")
	case strings.TrimSpace(it.Text) == "":
		return it, errors.New("text must be a non-empty string")
	case len(it.Text) > MaxTrackScanItemText:
		return it, fmt.Errorf("text is %d bytes; at most %d", len(it.Text), MaxTrackScanItemText)
	}
	if _, err := time.Parse(time.RFC3339, it.At); err != nil {
		return it, fmt.Errorf("at %q is not an RFC 3339 instant", it.At)
	}
	return it, nil
}

// BuiltinModule defines the built-in SDK, per declared capability (never
// keyed on the scope): a primitive's path (brief.compose for
// builtin:brief.compose, track.scan for track:scan) only when the manifest
// holds CapabilityForPrimitive(primitive), and builtin.defaultPrompt(name) and the
// builtin.input value when it holds any builtin: entry. builtin: entries are
// built-in only, so any other recipe sees none of them.
func BuiltinModule(b Backends) Module { return builtinModule{b: b} }

type builtinModule struct{ b Backends }

func (builtinModule) Name() string { return "builtin" }

// Install defines nothing: the built-in paths depend on the run's manifest
// (installFor).
func (builtinModule) Install(Definer) {}

func (m builtinModule) installFor(env *Env, d *definer) {
	man := env.Manifest
	if man == nil {
		return
	}
	s := newBuiltinSDK(m.b)
	for _, name := range sdkPrimitiveNames {
		if !man.has(CapabilityForPrimitive(name)) {
			continue
		}
		d.Define(name, func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
			raw, _, err := argAt(env, rt, call, 0)
			if err != nil {
				raw = nil
				err = tooLargeAs(err, ErrNameValidation, name+"(): the argument is too large")
			}
			return s.call(env, name, raw, err)
		})
	}
	if !slices.ContainsFunc(man.entries, func(p Permission) bool { return p.Capability == "builtin" }) {
		return
	}
	d.Define("builtin.defaultPrompt", s.defaultPrompt)
	d.defineValue("builtin.input", env.Trigger.Builtin)
}

// builtinSDK is one run's built-in SDK; the owner's role is read once.
type builtinSDK struct {
	b    Backends
	role func() (string, error)
}

func newBuiltinSDK(b Backends) *builtinSDK {
	return &builtinSDK{b: b, role: sync.OnceValues(func() (string, error) { return OwnerRole(b.DB) })}
}

// OwnerRole is the owner profile's role ("" without an owner or profile).
func OwnerRole(d *db.DB) (string, error) {
	if d == nil {
		return "", nil
	}
	o, err := d.ResolveOwner()
	if err != nil {
		return "", err
	}
	p, err := d.GetOwnerProfile(o)
	if err != nil || p == nil {
		return "", err
	}
	return p.Role, nil
}

func (s *builtinSDK) ownerRole() (string, error) {
	role, err := s.role()
	if err != nil {
		return "", notAvailable("reading the owner's role: " + err.Error())
	}
	return role, nil
}

// defaultPrompt is builtin.defaultPrompt(name): the shipped default of the
// built-in's prompt name for the owner's role.
func (s *builtinSDK) defaultPrompt(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
	v, _, err := argAt(env, rt, call, 0)
	name, ok := v.(string)
	if err != nil || !ok || strings.TrimSpace(name) == "" {
		return nil, validationf("builtin.defaultPrompt(name): name must be a non-empty string")
	}
	if s.b.DefaultPrompt == nil {
		return nil, notAvailable("no built-in prompts are available")
	}
	role, err := s.ownerRole()
	if err != nil {
		return nil, err
	}
	p, err := s.b.DefaultPrompt(builtinIDOf(env), name, role)
	if err != nil {
		return nil, validationf("builtin.defaultPrompt(%q): %v", name, err)
	}
	return p, nil
}

func builtinIDOf(env *Env) string {
	if env.Recipe != nil && env.Recipe.Scope.BuiltinID != "" {
		return env.Recipe.Scope.BuiltinID
	}
	if env.Automation != nil {
		return env.Automation.BuiltinID
	}
	return ""
}

// primitiveArgs is one primitive call's validated arguments.
type primitiveArgs struct {
	prompt string
	extra  map[string]any
}

// parsePrimitiveArgs reads the call's one argument {prompt, ...} (track.scan:
// {instruction, extra?}): an object whose prompt key (promptKeyOf) is a
// non-empty string and whose other keys the primitive takes and pass their
// check (primitiveExtraArgs). The prompt key is checked first, then the other
// keys in sorted order, so the error is the same on every run.
func parsePrimitiveArgs(name string, raw any) (primitiveArgs, error) {
	var a primitiveArgs
	key := promptKeyOf(name)
	obj, ok := raw.(map[string]any)
	if !ok {
		return a, validationf("%s({%s}): the argument must be an object", name, key)
	}
	keys := slices.Sorted(maps.Keys(obj))
	if i := slices.Index(keys, key); i > 0 {
		keys = slices.Concat([]string{key}, keys[:i], keys[i+1:])
	}
	for _, k := range keys {
		v := obj[k]
		check, extra := primitiveExtraArgs[name][k]
		switch {
		case k == key:
			p, ok := v.(string)
			if !ok || strings.TrimSpace(p) == "" {
				return a, validationf("%s({%s}): %s must be a non-empty string", name, key, key)
			}
			a.prompt = p
		case extra:
			checked, err := check(v)
			if err != nil {
				return a, err
			}
			if a.extra == nil {
				a.extra = map[string]any{}
			}
			a.extra[k] = checked
		default:
			return a, validationf("%s(): unknown argument %q", name, k)
		}
	}
	if a.prompt == "" {
		return a, validationf("%s({%s}): %s must be a non-empty string", name, key, key)
	}
	return a, nil
}

func (a primitiveArgs) stepArgs(name string) map[string]any {
	out := maps.Clone(a.extra)
	if out == nil {
		out = map[string]any{}
	}
	out[promptKeyOf(name)] = a.prompt
	return out
}

// call runs one primitive call as one llm step named after the primitive:
// the permission CapabilityForPrimitive(name) first, then the arguments
// (argErr is a bad argument found before the step began), then — except in a
// dry run, which calls nothing (a capture dry run reports the prompt first,
// DryRunOptions.CapturePrompts) — the primitive under the run's meter.
func (s *builtinSDK) call(env *Env, name string, raw any, argErr error) (any, error) {
	var args primitiveArgs
	if argErr == nil {
		args, argErr = parsePrimitiveArgs(name, raw)
	}
	return env.Call(StepKindLLM, name, args.stepArgs(name), func(step *Step) (any, error) {
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
		input := env.Trigger.Builtin
		if env.DryRun || env.Trigger.DryRun {
			if env.capturePrompt != nil {
				env.capturePrompt(name, args.prompt)
			}
			return dryRunResult(step, primitiveDryRunSummary(env, name, input)), nil
		}
		fn := s.b.Primitives[name]
		if fn == nil {
			return nil, notAvailable(name + " is not available")
		}
		role, err := s.ownerRole()
		if err != nil {
			return nil, err
		}
		pc := PrimitiveCall{Name: name, BuiltinID: builtinIDOf(env), Prompt: args.prompt, Args: maps.Clone(args.extra),
			Trigger: env.Trigger, Input: input, Role: role}
		var res PrimitiveResult
		err = env.MeteredModelCall(step, func(ctx context.Context) (ModelUsage, error) {
			var err error
			res, err = fn(ctx, pc)
			if err == nil && res.Status != primitiveDone && res.Status != primitiveSkipped {
				err = fmt.Errorf("%s returned status %q (want %q or %q)", name, res.Status, primitiveDone, primitiveSkipped)
			}
			if err != nil {
				return primitiveUsage(res.Usage), &SDKError{Name: ErrNamePrimitiveFailed, Message: err.Error()}
			}
			return primitiveUsage(res.Usage), nil
		})
		if err != nil {
			return nil, err
		}
		return primitiveOutcome(step, res), nil
	})
}

// primitiveDryRunSummary is a dry run's step summary: what would run, and
// on which date (track.scan: from which instant, when the input says).
func primitiveDryRunSummary(env *Env, name string, in BuiltinInput) map[string]any {
	if name != primitiveTrackScan {
		return map[string]any{"would": name, "date": runDate(env, in)}
	}
	out := map[string]any{"would": name}
	if in.Since != "" {
		out["since"] = in.Since
	}
	return out
}

// runDate is the date a slot run works on: its input's, else today (local).
func runDate(env *Env, in BuiltinInput) string {
	if in.Date != "" {
		return in.Date
	}
	return env.Meter.clock.Now().In(time.Local).Format(time.DateOnly)
}

func primitiveUsage(u PrimitiveUsage) ModelUsage {
	mu := ModelUsage{InputTokens: int64(u.InputTokens), OutputTokens: int64(u.OutputTokens)}
	if u.Reported {
		cost := u.CostUSD
		mu.ReportedUSD = &cost
	}
	return mu
}

// primitiveOutcome is what the script gets, {status, ...Fields}; a Note is
// journalled on the step next to it (the script does not see it).
func primitiveOutcome(step *Step, res PrimitiveResult) map[string]any {
	out := maps.Clone(res.Fields)
	if out == nil {
		out = map[string]any{}
	}
	out["status"] = res.Status
	if res.Note != "" {
		summary := maps.Clone(out)
		summary["note"] = res.Note
		step.Finish(db.StepFinish{Status: StepOK, ResultSummary: marshalForStep(summary)})
	}
	return out
}
