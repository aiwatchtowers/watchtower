package builtin

import (
	"context"
	"errors"
	"fmt"
	"log"
	"runtime/debug"
	"sync"

	"watchtower/internal/automations"
	"watchtower/internal/db"
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
	composed bool // reaction.compose took the command
	stored   bool // and DispatchWith returned out
	out      reactioncmd.Outcome
}

// NewReactionSlot returns an empty slot.
func NewReactionSlot() *ReactionSlot {
	return &ReactionSlot{pending: map[int64]*reactionCall{}}
}

// ErrReactionRunBusy is Begin's refusal of a run that already carries a
// command (an enqueue that coalesced into a still-queued run).
var ErrReactionRunBusy = errors.New("the run already carries a reaction command")

// strandedNote is End's detail for a run that ended while reaction.compose
// was still dispatching.
const strandedNote = "the run ended before reaction.compose returned"

// Begin hands d to run runID. A run that already carries a command is
// refused with ErrReactionRunBusy and keeps its first command.
func (s *ReactionSlot) Begin(runID int64, d reactioncmd.Dispatch) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.pending[runID]; ok {
		return fmt.Errorf("run %d: %w", runID, ErrReactionRunBusy)
	}
	s.pending[runID] = &reactionCall{d: d}
	return nil
}

// End removes run runID's command and returns the Outcome reaction.compose
// stored; false = the script never called reaction.compose (or the run was
// never Begun). A run that ended while its compose was still dispatching
// (an abandoned script) returns a StepStrand outcome: whether an action was
// proposed is unknown.
func (s *ReactionSlot) End(runID int64) (reactioncmd.Outcome, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.pending[runID]
	delete(s.pending, runID)
	switch {
	case !ok || !c.composed:
		return reactioncmd.Outcome{}, false
	case !c.stored:
		return reactioncmd.Outcome{Step: reactioncmd.StepStrand, Detail: strandedNote}, true
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
		c.out, c.stored = out, true
	}
}

// ReactionPrimitives returns reaction.compose over p and s: it composes the
// run's pending Dispatch once with the recipe's prompt (DispatchWith) and
// stores the Outcome for the pass's End. A dispatched outcome returns
// {status: "done", outcome: "dispatched", action_id} (the SDK admits only
// done|skipped as a primitive's status); any other outcome — a failed
// finalize, a release or a strand — is stored the same way and then fails
// the call with its detail, so the run's status is honest. Its usage is the
// compose call's (Outcome.Usage), failed or not, so the run row, Costs and
// the recipe's token budget see it.
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
			usage := automations.PrimitiveUsage{InputTokens: out.Usage.InputTokens, OutputTokens: out.Usage.OutputTokens}
			if out.Step != reactioncmd.StepFinalize || out.Status != reactionDispatched {
				return automations.PrimitiveResult{Usage: usage}, fmt.Errorf("the reaction was not dispatched (%s): %s",
					outcomeKind(out), out.Detail)
			}
			return automations.PrimitiveResult{Status: "done", Usage: usage,
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

// reactionsID is the Reactions built-in's id.
const reactionsID = "reactions"

// ReactionDispatch is the reaction pass's dispatcher over runner r and slot
// s (the daemon's and `reaction-commands poll`'s alike): each claimed
// command goes through one sync run of the Reactions built-in — queued (so
// its id is known), handed the command (ReactionSlot.Begin), executed
// inline, and Ended, on every path, a panic included. The Outcome
// reaction.compose stored is returned as it is. A run that composed nothing
// finalizes failed (nothing was proposed, and a script that does not
// compose would fail again), except when its script never got to run: no
// run could be queued or handed the command, its claim lost, or it became
// not runnable; and when the pass was cancelled (a shutdown or a sleep must
// not burn the claimed reactions). Those release the row for the next poll:
// nothing was composed.
func ReactionDispatch(r *Runner, s *ReactionSlot, logger *log.Logger) reactioncmd.Dispatcher {
	if logger == nil {
		logger = log.Default()
	}
	return func(ctx context.Context, rd reactioncmd.Dispatch) reactioncmd.Outcome {
		return dispatchReaction(ctx, r, s, logger, rd)
	}
}

func dispatchReaction(ctx context.Context, r *Runner, s *ReactionSlot, logger *log.Logger, rd reactioncmd.Dispatch) (out reactioncmd.Outcome) {
	run, err := r.EnqueueSync(reactionsID, automations.BuiltinInput{})
	if err != nil {
		logger.Printf("reaction-commands: queueing a Reactions run for :%s:, will retry: %v", rd.Emoji, err)
		return reactioncmd.Outcome{Step: reactioncmd.StepRelease}
	}
	if err := s.Begin(run.ID, rd); err != nil {
		logger.Printf("reaction-commands: handing :%s: to Reactions run %d, will retry: %v", rd.Emoji, run.ID, err)
		return reactioncmd.Outcome{Step: reactioncmd.StepRelease}
	}
	var finished *db.AutomationRun
	var execErr error
	defer func() {
		rec := recover()
		stored, composed := s.End(run.ID)
		if rec != nil {
			logger.Printf("reaction-commands: ERROR Reactions run %d panicked for :%s: (%s, composed=%t): %v\n%s",
				run.ID, rd.Emoji, rd.Tool, composed, rec, debug.Stack())
		}
		switch {
		case composed:
			out = stored
		case rec != nil:
			out = noComposeOutcome(fmt.Sprintf("panic: %v", rec))
		case ctx.Err() != nil, errors.Is(execErr, automations.ErrRunNotClaimed), errors.Is(execErr, automations.ErrNotRunnable):
			logger.Printf("reaction-commands: Reactions run %d for :%s: did not run, will retry: %v", run.ID, rd.Emoji, errors.Join(execErr, ctx.Err()))
			out = reactioncmd.Outcome{Step: reactioncmd.StepRelease}
		default:
			out = noComposeOutcome(runErrorText(finished, execErr))
		}
	}()
	finished, execErr = r.ExecuteRun(ctx, run.ID)
	return out
}

// noComposeOutcome is the failed finalize of a Reactions run that never
// called reaction.compose; why is its run error or "no compose call".
func noComposeOutcome(why string) reactioncmd.Outcome {
	return reactioncmd.Outcome{Status: "failed", Step: reactioncmd.StepFinalize,
		Detail: "the Reactions automation did not compose: " + why}
}

// runErrorText is a finished run's error, the executor's, or "no compose
// call" when the run ended without one.
func runErrorText(run *db.AutomationRun, err error) string {
	switch {
	case run != nil && run.Error != "":
		return run.Error
	case err != nil:
		return err.Error()
	}
	return "no compose call"
}
