package llmusage

import "context"

type (
	purposeKey    struct{}
	surfaceKey    struct{}
	automationKey struct{}
)

type automationIDs struct{ automationID, runID int64 }

// WithPurpose returns a context whose LLM calls are recorded with purpose
// (digest.WithSource is a wrapper over it).
func WithPurpose(ctx context.Context, purpose string) context.Context {
	return context.WithValue(ctx, purposeKey{}, purpose)
}

// PurposeFrom returns the purpose attached by WithPurpose; an empty one is
// reported as absent.
func PurposeFrom(ctx context.Context) (string, bool) {
	p, ok := ctx.Value(purposeKey{}).(string)
	return p, ok && p != ""
}

// WithSurface returns a context whose LLM calls are recorded on surface
// (watchtower, chat or workbench) instead of the process default.
func WithSurface(ctx context.Context, surface string) context.Context {
	return context.WithValue(ctx, surfaceKey{}, surface)
}

// SurfaceFrom returns the surface attached by WithSurface; an empty one is
// reported as absent.
func SurfaceFrom(ctx context.Context) (string, bool) {
	s, ok := ctx.Value(surfaceKey{}).(string)
	return s, ok && s != ""
}

// WithAutomation returns a context whose LLM calls are recorded against an
// automation run.
func WithAutomation(ctx context.Context, automationID, runID int64) context.Context {
	return context.WithValue(ctx, automationKey{}, automationIDs{automationID, runID})
}

// AutomationFrom returns the ids attached by WithAutomation.
func AutomationFrom(ctx context.Context) (automationID, runID int64, ok bool) {
	ids, ok := ctx.Value(automationKey{}).(automationIDs)
	return ids.automationID, ids.runID, ok
}

// Attempt links physical leaf calls to a logical routing operation. It carries
// no provider/model: those remain the leaf's actual values.
type Attempt struct {
	OperationID string
	Number      int
	Revision    string
}
type attemptKey struct{}
type attemptContext struct {
	attempt Attempt
	observe func(Call)
}

// WithAttempt attaches linkage and a leaf-completion observer. Observers must
// be safe for the leaf's calling goroutine and must not write another row.
func WithAttempt(ctx context.Context, attempt Attempt, observe func(Call)) context.Context {
	return context.WithValue(ctx, attemptKey{}, attemptContext{attempt, observe})
}
