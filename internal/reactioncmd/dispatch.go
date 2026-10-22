package reactioncmd

import (
	"context"
	"errors"
	"fmt"
	"watchtower/internal/prompts"
	"watchtower/internal/tools"
)

// Dispatch is one claimed command handed to a dispatcher: the ledger row is
// already provisional, the budget slot taken and an issue tool already routed
// to its tracker (Tool is the routed name). The unexported fields carry what
// the built-in dispatch needs, so only a Dispatch built by the pipeline can be
// handed to DispatchWith.
type Dispatch struct {
	AccountID int64
	ChannelID string // namespaced accountID:rawID
	MessageTS string
	ThreadTS  string
	Emoji     string
	Tool      string // the routed tool name (after routeIssue)

	c      candidate
	tool   *tools.Tool
	thread []string // the thread's lines, read once for routing and compose
}

// Step is what the pipeline does with a claimed provisional ledger row once a
// dispatcher returns.
type Step int

const (
	// StepFinalize records the returned terminal status on the row.
	StepFinalize Step = iota
	// StepRelease deletes the row: the failure was transient and provably
	// produced no agent action, so the next poll retries.
	StepRelease
	// StepStrand leaves the row provisional: whether an action was recorded is
	// unknown, so the command is never retried and surfaces as failed after
	// strandedAfter.
	StepStrand
)

// Outcome is a dispatcher's result. With StepFinalize, Status is the terminal
// ledger status (dispatched|failed), ActionID the agent-action id (0 unless
// dispatched) and Detail the ledger's error text; the other steps ignore them.
type Outcome struct {
	Status   string
	ActionID int64
	Detail   string
	Step     Step
}

// Dispatcher runs one claimed command. The pipeline keeps the budget, the
// claim, the finalize and the stranding; a dispatcher only decides the outcome.
type Dispatcher func(ctx context.Context, d Dispatch) Outcome

// SetDispatcher replaces the dispatcher claimed commands are handed to; nil
// restores the built-in one (DispatchWith with the prompt store's prompt).
// Safe to call while a poll runs: a command already handed over keeps its
// dispatcher.
func (p *Pipeline) SetDispatcher(fn Dispatcher) {
	if fn == nil {
		p.dispatcher.Store(nil)
		return
	}
	p.dispatcher.Store(&fn)
}

// SetDispatchPaused stops (true) or resumes (false) dispatching. A paused
// poll still seeds unseeded accounts and publishes reaction events (it lists
// reactions only through the event path), but claims nothing: no ledger row is
// written and no budget is spent, so every command placed meanwhile stays
// unseen and is dispatched once resumed.
func (p *Pipeline) SetDispatchPaused(paused bool) { p.paused.Store(paused) }

// dispatchPaused reports whether SetDispatchPaused(true) is in effect.
func (p *Pipeline) dispatchPaused() bool { return p.paused.Load() }

// runDispatcher hands d to the custom dispatcher (or DispatchWith) and returns
// an Outcome the ledger can record: a panic or an outcome that is neither a
// release, a strand nor a finalize with dispatched/failed becomes a finalize
// with failed, naming what went wrong, so one bad dispatch never stops the
// pass or leaves a row the ledger CHECK refuses.
func (p *Pipeline) runDispatcher(ctx context.Context, d Dispatch) (out Outcome) {
	defer func() {
		if r := recover(); r != nil {
			p.logf("reaction-commands: ERROR dispatcher panicked for :%s: (%s): %v", d.Emoji, d.Tool, r)
			out = Outcome{Status: "failed", Detail: fmt.Sprintf("dispatcher panic: %v", r), Step: StepFinalize}
		}
	}()
	if fn := p.dispatcher.Load(); fn != nil {
		out = (*fn)(ctx, d)
	} else {
		out = p.DispatchWith(ctx, d, "")
	}
	return normaliseOutcome(out)
}

// normaliseOutcome turns an outcome the ledger cannot record into a failed
// finalize whose detail names the bad outcome.
func normaliseOutcome(out Outcome) Outcome {
	switch out.Step {
	case StepRelease, StepStrand:
		return out
	case StepFinalize:
		if out.Status == "dispatched" || out.Status == "failed" {
			return out
		}
	}
	return Outcome{
		Status: "failed",
		Detail: fmt.Sprintf("dispatcher returned an invalid outcome (step %d, status %q)", out.Step, out.Status),
		Step:   StepFinalize,
	}
}

// DispatchWith is the built-in dispatch: it composes the tool's arguments with
// prompt as the system prompt ("" = the prompt store's reaction-command
// prompt) and proposes the action on the reaction surface. With StepFinalize
// the Outcome carries the terminal status (dispatched/failed); StepRelease
// marks a TRANSIENT failure that produced no action (the pipeline releases the
// row so the next poll retries), StepStrand one whose outcome is unknown.
func (p *Pipeline) DispatchWith(ctx context.Context, d Dispatch, prompt string) Outcome {
	if d.tool == nil {
		return Outcome{Status: "failed", Detail: "dispatch: no resolved tool", Step: StepFinalize}
	}
	c, tool := d.c, d.tool
	if prompt == "" {
		prompt, _ = p.getPrompt(prompts.ReactionCommand)
	}
	args, transient, err := p.compose(ctx, c, tool.Name, d.thread, prompt)
	if err != nil {
		if transient {
			p.logf("reaction-commands: transient compose failure for :%s: (%s), will retry: %v", c.Emoji, tool.Name, err)
			return Outcome{Step: StepRelease}
		}
		return Outcome{Status: "failed", Detail: "compose: " + err.Error(), Step: StepFinalize}
	}
	// Surface "reaction" keeps these proposals out of any chat conversation;
	// the External-never-auto-execute rule (AGENT-03) and trust per tool and
	// surface are enforced inside Propose, so a create_jira_issue or
	// create_linear_issue reaction always lands as a pending proposal even if
	// create_target is execute-trusted.
	binding := tools.Binding{
		Surface:     reactionSurface,
		ContextType: "reaction",
		ContextID:   c.ChannelID + "@" + c.MessageTS, // REACT-02: real message ref for reminders/brief
	}
	// The agent_actions high-water mark before Propose lets a failed Propose be
	// told apart: "recorded a row, then failed" vs "recorded nothing".
	floor, err := p.db.MaxAgentActionID()
	if err != nil {
		p.logf("reaction-commands: reading agent-action high-water mark for :%s: failed, will retry: %v", c.Emoji, err)
		return Outcome{Step: StepRelease}
	}
	receipt, err := p.registry.Propose(ctx, tool.Name, args, binding)
	if err != nil {
		// A ValidationError is terminal — the model's args cannot pass the
		// tool's schema/semantics, and re-composing the same message would only
		// spend AI budget to fail again.
		var ve *tools.ValidationError
		if errors.As(err, &ve) {
			return Outcome{Status: "failed", Detail: "propose: " + err.Error(), Step: StepFinalize}
		}
		return p.afterProposeError(c, tool.Name, binding.ContextID, floor, err)
	}
	return Outcome{Status: "dispatched", ActionID: receipt.ActionID, Step: StepFinalize}
}

// afterProposeError classifies a non-validation Propose error. Propose can fail
// AFTER inserting its agent_actions row (a failed approve stamp or apply
// bookkeeping on an execute-trusted tool), so the error alone does not prove
// nothing was proposed: a row recorded since `floor` for this binding means the
// command dispatched (finalize with that id); none means the failure was
// transient before any write (release, retry next poll); a failed lookup
// leaves the outcome unknown (strand).
func (p *Pipeline) afterProposeError(c candidate, toolName, contextID string, floor int64, proposeErr error) Outcome {
	id, err := p.db.ReactionAgentActionSince(contextID, toolName, floor)
	if err != nil {
		p.logf("reaction-commands: ERROR propose for :%s: failed (%v) and the recorded-action lookup failed too: %v", c.Emoji, proposeErr, err)
		return Outcome{Step: StepStrand}
	}
	if id != 0 {
		p.logf("reaction-commands: propose for :%s: failed after recording action #%d — recording it as dispatched, not retrying: %v", c.Emoji, id, proposeErr)
		return Outcome{Status: "dispatched", ActionID: id, Detail: "propose error after recording: " + proposeErr.Error(), Step: StepFinalize}
	}
	p.logf("reaction-commands: transient propose failure for :%s:, nothing recorded, will retry: %v", c.Emoji, proposeErr)
	return Outcome{Step: StepRelease}
}
