package builtin

import (
	"context"
	"fmt"
	"sync"

	"watchtower/internal/automations"
	"watchtower/internal/reactioncmd"
)

// ReactionDispatcher is the reaction-commands pipeline as reaction.compose
// calls it (*reactioncmd.Pipeline).
type ReactionDispatcher interface {
	DispatchWith(ctx context.Context, d reactioncmd.Dispatch, prompt string) reactioncmd.Outcome
}

// ReactionSlot carries the one claimed command a Reactions run handles: the
// reaction pass Begins a run with its Dispatch, executes the run, and Ends it
// to read the Outcome reaction.compose stored.
type ReactionSlot struct {
	mu      sync.Mutex
	pending map[int64]*reactionCall // by run id
}

// reactionCall is one run's command and, once composed, its outcome.
type reactionCall struct {
	d        reactioncmd.Dispatch
	composed bool
	out      reactioncmd.Outcome
}

// NewReactionSlot returns an empty slot.
func NewReactionSlot() *ReactionSlot {
	return &ReactionSlot{pending: map[int64]*reactionCall{}}
}

// Begin hands d to run runID (it replaces a Dispatch Begun earlier for the
// same run).
func (s *ReactionSlot) Begin(runID int64, d reactioncmd.Dispatch) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pending[runID] = &reactionCall{d: d}
}

// End removes run runID's command and returns the Outcome reaction.compose
// stored; false = the script never called reaction.compose (or the run was
// never Begun).
func (s *ReactionSlot) End(runID int64) (reactioncmd.Outcome, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.pending[runID]
	delete(s.pending, runID)
	if !ok || !c.composed {
		return reactioncmd.Outcome{}, false
	}
	return c.out, true
}

// take marks run runID's command composed and returns it; an error when the
// run has none or already composed it.
func (s *ReactionSlot) take(runID int64) (reactioncmd.Dispatch, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.pending[runID]
	switch {
	case !ok:
		return reactioncmd.Dispatch{}, validationError("reaction.compose(): this run has no reaction to compose")
	case c.composed:
		return reactioncmd.Dispatch{}, validationError("reaction.compose(): this run already composed its reaction")
	}
	c.composed = true
	return c.d, nil
}

// store records run runID's outcome (a run Ended meanwhile keeps nothing).
func (s *ReactionSlot) store(runID int64, out reactioncmd.Outcome) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c, ok := s.pending[runID]; ok {
		c.out = out
	}
}

// ReactionPrimitives returns reaction.compose over p and s: it composes the
// run's pending Dispatch once with the recipe's prompt (DispatchWith) and
// stores the Outcome for the pass's End. A dispatched outcome returns
// {status: "done", outcome: "dispatched", action_id} (the SDK admits only
// done|skipped as a primitive's status); any other outcome — a failed
// finalize, a release or a strand — is stored the same way and then fails
// the call with its detail, so the run's status is honest. Its usage is
// zero: reactioncmd does not meter, the run row is the history.
func ReactionPrimitives(p ReactionDispatcher, s *ReactionSlot) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		"reaction.compose": func(ctx context.Context, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if p == nil || s == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			d, err := s.take(call.Trigger.RunID)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			out := p.DispatchWith(ctx, d, call.Prompt)
			s.store(call.Trigger.RunID, out)
			if out.Step != reactioncmd.StepFinalize || out.Status != reactionDispatched {
				return automations.PrimitiveResult{}, fmt.Errorf("the reaction was not dispatched (%s): %s",
					outcomeKind(out), out.Detail)
			}
			return automations.PrimitiveResult{Status: "done",
				Fields: map[string]any{"outcome": out.Status, "action_id": out.ActionID}}, nil
		},
	}
}

// reactionDispatched is the ledger status of a composed and proposed command.
const reactionDispatched = "dispatched"

// outcomeKind names a non-dispatched outcome for the step's error.
func outcomeKind(out reactioncmd.Outcome) string {
	switch out.Step {
	case reactioncmd.StepRelease:
		return "released for a retry"
	case reactioncmd.StepStrand:
		return "outcome unknown"
	case reactioncmd.StepFinalize:
	}
	if out.Status == "" {
		return "no status"
	}
	return out.Status
}

// validationError is a primitive's ValidationError (the script's fault).
func validationError(msg string) error {
	return &automations.SDKError{Name: automations.ErrNameValidation, Message: msg}
}
