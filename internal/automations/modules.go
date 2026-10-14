package automations

import (
	"maps"
	"slices"

	"watchtower/internal/db"
)

// Step kinds the P1 modules journal (automation_run_steps.kind).
const (
	StepKindLLM    = "llm"
	StepKindTool   = "tool"
	StepKindState  = "state"
	StepKindOutput = "output"
	StepKindLog    = "log"
)

// DefaultModules is the SDK every run gets, in install order: llm, tool,
// state, output, log. Later phases append their modules here (a later
// Define of the same path replaces the earlier one) and register further
// output kinds on the *OutputMod with closures over b.
func DefaultModules(b Backends) []Module {
	return []Module{LLMModule(b), ToolModule(b), StateModule(), OutputModule(), LogModule()}
}

// sdkModule is a Module defining a fixed set of paths.
type sdkModule struct {
	name string
	fns  map[string]SDKFunc
}

func (m sdkModule) Name() string { return m.name }

func (m sdkModule) Install(def Definer) {
	for _, p := range slices.Sorted(maps.Keys(m.fns)) {
		def.Define(p, m.fns[p])
	}
}

// manifestOf is the run's manifest; a run without one may do nothing that
// needs a permission.
func manifestOf(env *Env) (*Manifest, error) {
	if env.Manifest == nil {
		return nil, &PermissionDenied{Reason: "the run has no permission manifest"}
	}
	return env.Manifest, nil
}

// dryRunResult is what a write returns in a dry run; it closes step as
// dry_run with summary (the would-be write).
func dryRunResult(step *Step, summary any) map[string]any {
	step.Finish(db.StepFinish{Status: StepDryRun, ResultSummary: marshalForStep(summary)})
	return map[string]any{"status": StepDryRun}
}

func notAvailable(msg string) error {
	return &SDKError{Name: ErrNameNotAvailable, Message: msg}
}
