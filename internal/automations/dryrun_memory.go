package automations

import (
	"context"
	"errors"
	"fmt"
	"math"

	"watchtower/internal/db"
)

// DryRunOptions tunes DryRunInMemory.
type DryRunOptions struct {
	// Budget bounds the dry run; a zero field takes the recipe's value (and
	// the recipe default when that is zero too).
	Budget Budget
	// Modules builds the SDK; nil = DefaultModules.
	Modules func(Backends) []Module
}

// DryRunReport is what a dry run in memory did.
type DryRunReport struct {
	Steps                     []db.AutomationRunStep
	Outputs                   []db.AutomationOutput // the would-be outputs, never committed
	InputTokens, OutputTokens int64
	Estimated                 bool
	// Status is the terminal status the run would have had (succeeded,
	// failed, budget_exceeded, timed_out, cancelled); Error its message.
	Status, Error string
}

// DryRunInMemory dry-runs r without writing any row (P3's draft_automation,
// AGENT-06): a memory journal, a synthetic run with ID 0, no Waiter (a
// wait-capable call answers dry_run before it would wait), no daily cap (a
// draft's tokens do not count toward it — a v1 limit) and a commit buffer
// that starts empty and is never committed. Backends.DB is touched only by
// AllowTool's read-only lookups. The error is for an unusable request (no
// recipe, a manifest that does not parse); how the script ended is in the
// report.
func DryRunInMemory(ctx context.Context, b Backends, r *Recipe, opts DryRunOptions) (*DryRunReport, error) {
	if r == nil {
		return nil, errors.New("dry run in memory: no recipe")
	}
	m, err := ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return nil, fmt.Errorf("dry run in memory: %w", err)
	}
	clock := b.Clock
	if clock == nil {
		clock = RealClock{}
	}
	modules := opts.Modules
	if modules == nil {
		modules = DefaultModules
	}
	env := &Env{
		Ctx: ctx, Run: &db.AutomationRun{ID: 0, Trigger: db.TriggerDryRun}, Recipe: r, Manifest: m, DryRun: true,
		Journal: NewMemoryJournal().UseClock(clock),
		Meter:   NewMeter(dryRunBudget(opts.Budget, r.Budget), math.MaxInt64, clock),
		Buffer:  NewCommitBuffer(nil),
		Trigger: TriggerInfo{Kind: db.TriggerDryRun, DryRun: true},
	}
	sb, runErr := NewSandbox(env, modules(b))
	if runErr == nil {
		_, runErr = sb.Run()
	}
	totals := env.Journal.Totals()
	rep := &DryRunReport{
		Steps: env.Journal.Steps(), Outputs: env.Buffer.Outputs(),
		InputTokens: totals.InputTokens, OutputTokens: totals.OutputTokens, Estimated: totals.Estimated,
		Status: db.RunSucceeded,
	}
	if runErr != nil {
		end := classifyRunError(runErr)
		rep.Status, rep.Error = end.status, end.msg
	}
	return rep, nil
}

// dryRunBudget fills opts' zero fields from the recipe, then the defaults.
func dryRunBudget(opts, recipe Budget) Budget {
	b := opts
	if b.Tokens <= 0 {
		b.Tokens = recipe.Tokens
	}
	if b.Tokens <= 0 {
		b.Tokens = DefaultBudgetTokens
	}
	if b.Minutes <= 0 {
		b.Minutes = recipe.Minutes
	}
	if b.Minutes <= 0 {
		b.Minutes = DefaultBudgetMinutes
	}
	return b
}
