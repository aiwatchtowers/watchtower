package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// runEnd is how a run ends: its terminal status, error kind and message.
type runEnd struct {
	status, kind, msg string
	// abandoned: the script goroutine was left behind (AbandonedRuns).
	abandoned bool
}

func failedEnd(kind string, err error) *runEnd {
	return &runEnd{status: db.RunFailed, kind: kind, msg: err.Error()}
}

// runClaimed executes a run this executor claimed and finishes it. Every
// claimed run reaches a terminal status here, unless the database refuses
// the finish (logged; the next daemon start ends it as interrupted).
// inline is ExecuteInline's run (the CLI's dry run): a ctx that ends there
// is the CLI stopping, not the daemon.
func (e *Executor) runClaimed(ctx context.Context, runID int64, a *db.Automation, inline bool) {
	defer e.Wake() // a finished run frees a slot: claim the next queued run, resume a waiting one
	run, err := e.db.GetAutomationRun(runID)
	if errors.Is(err, db.ErrAutomationRunNotFound) {
		return // deleted with its workbench (cascade): nothing left to finish
	}
	if err != nil {
		e.logger.Printf("automations: run %d: reading the claimed run: %v", runID, err)
		e.finish(runID, a, db.RunFinish{Status: db.RunFailed, ErrorKind: db.ErrKindBackend, Error: err.Error()}, nil, false)
		return
	}
	env, sb, end := e.prepare(ctx, run, a)
	if end != nil {
		e.finish(runID, a, db.RunFinish{Status: end.status, ErrorKind: end.kind, Error: end.msg}, nil, false)
		return
	}
	v, runErr := e.runSandbox(env, sb)
	if e.runGone(runID) {
		return
	}
	f, commit, abandoned := e.outcome(ctx, env, v, runErr, inline)
	e.finish(runID, a, f, commit, abandoned)
}

// runGone reports whether the run's row is gone: a workbench delete removes
// its automations' runs by cascade (PROJ-02) while one may be in flight. The
// run then ends quietly — its journal writes failed against the vanished
// rows, and there is nothing left to finish or report.
func (e *Executor) runGone(runID int64) bool {
	_, err := e.db.GetAutomationRun(runID)
	return errors.Is(err, db.ErrAutomationRunNotFound)
}

// prepare re-parses the run's snapshot (never the file) and builds its
// sandbox. A non-nil runEnd ends the run before any script code runs: a
// snapshot that does not parse (failed/not_runnable), a malformed event payload or an unreadable
// store (failed/backend), a script that does not compile (failed/script).
func (e *Executor) prepare(ctx context.Context, run *db.AutomationRun, a *db.Automation) (*Env, *Sandbox, *runEnd) {
	scope := Scope{Kind: ScopeKind(a.Scope), WorkbenchID: a.ProjectID}
	r, err := ParseRecipe(a.Slug, []byte(run.RecipeSnapshot), scope)
	if err != nil {
		return nil, nil, failedEnd(db.ErrKindNotRunnable, fmt.Errorf("the recipe does not parse: %w", err))
	}
	m, err := ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return nil, nil, failedEnd(db.ErrKindNotRunnable, fmt.Errorf("the permission manifest does not parse: %w", err))
	}
	trig, err := triggerInfo(run, r)
	if err != nil {
		return nil, nil, failedEnd(db.ErrKindBackend, err)
	}
	meter := e.newMeter(run, r)
	state, err := e.db.GetAutomationState(a.ID)
	if err != nil {
		return nil, nil, failedEnd(db.ErrKindBackend, err)
	}
	dry := run.Trigger == db.TriggerDryRun
	env := &Env{
		Ctx: withRunWait(ctx, &runWait{runID: run.ID, meter: meter, pauseTimeout: pauseTimeout(r)}),
		Run: run, Automation: a, Recipe: r, Manifest: m, DryRun: dry,
		Journal: NewJournal(e.db, run.ID, dry).UseClock(e.clock),
		Meter:   meter, Buffer: NewCommitBuffer(state), Wait: e.Waiter(), Trigger: trig,
	}
	sb, err := NewSandbox(env, e.modules(e.b))
	if err != nil {
		return nil, nil, classifyRunError(err)
	}
	return env, sb, nil
}

// newMeter starts the run's meter on its snapshotted budgets (the recipe's
// when the run carries none). There is no daily cap across runs (D25, ask
// #294).
func (e *Executor) newMeter(run *db.AutomationRun, r *Recipe) *Meter {
	budget := Budget{Tokens: run.BudgetTokens, Minutes: run.BudgetMinutes}
	if budget.Tokens <= 0 {
		budget.Tokens = r.Budget.Tokens
	}
	if budget.Minutes <= 0 {
		budget.Minutes = r.Budget.Minutes
	}
	return NewMeter(budget, e.clock)
}

func pauseTimeout(r *Recipe) time.Duration {
	h := r.PauseTimeoutHours
	if h <= 0 {
		h = DefaultPauseTimeoutHours
	}
	return time.Duration(h) * time.Hour
}

// triggerInfo builds the script's trigger object. An event run's event_json
// must decode as db.AutomationEventPayload with every event an object (S5);
// so must a dry run's, when it carries one (the events an event recipe's dry
// run plays).
func triggerInfo(run *db.AutomationRun, r *Recipe) (TriggerInfo, error) {
	t := TriggerInfo{
		Kind: run.Trigger, RunID: run.ID, ScheduledFor: run.ScheduledFor,
		CatchUp: run.Trigger == db.TriggerCatchUp, DryRun: run.Trigger == db.TriggerDryRun,
	}
	if run.Trigger == db.TriggerButton && r.Trigger.Button != nil {
		t.Button = r.Trigger.Button.Label
	}
	if run.Trigger != db.TriggerEvent && (run.Trigger != db.TriggerDryRun || run.EventJSON == "") {
		return t, nil
	}
	var p db.AutomationEventPayload
	if err := json.Unmarshal([]byte(run.EventJSON), &p); err != nil {
		return t, fmt.Errorf("decoding the run's event payload: %w", err)
	}
	t.Events = make([]map[string]any, 0, len(p.Events))
	for i, raw := range p.Events {
		var ev map[string]any
		if err := json.Unmarshal(raw, &ev); err != nil || ev == nil {
			return t, fmt.Errorf("decoding the run's event payload: event %d is not an object", i)
		}
		t.Events = append(t.Events, ev)
	}
	t.Truncated = p.Truncated
	return t, nil
}

// runSandbox runs the script while a watcher re-reads the run's status every
// PollInterval and on Wake: a run ended from outside (a CLI cancel) is
// interrupted.
func (e *Executor) runSandbox(env *Env, sb *Sandbox) (any, error) {
	done, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		e.watchStatus(env.Run.ID, sb, done)
	}()
	v, err := sb.Run()
	close(done)
	<-watched
	return v, err
}

func (e *Executor) watchStatus(runID int64, sb *Sandbox, done <-chan struct{}) {
	for {
		nudge := e.nudged()
		ended, err := e.runEnded(runID)
		if err != nil {
			e.logger.Printf("automations: run %d: re-reading its status: %v", runID, err)
		}
		if ended {
			sb.Interrupt(InterruptCancel)
			return
		}
		select {
		case <-done:
			return
		case <-nudge:
		case <-e.clock.After(PollInterval):
		}
	}
}

// runEnded reports whether the run is no longer active (cancelled, ended by
// anyone but this executor, or its row deleted with its workbench).
func (e *Executor) runEnded(runID int64) (bool, error) {
	r, err := e.db.GetAutomationRun(runID)
	if errors.Is(err, db.ErrAutomationRunNotFound) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return r.Status != db.RunRunning && r.Status != db.RunWaiting, nil
}

// outcome maps the script's result to the run's finish: success commits the
// buffer (never for a dry run) unless the journal failed to write; a cancel
// that came from the daemon stopping (ctx done) is interrupted, not
// cancelled.
func (e *Executor) outcome(ctx context.Context, env *Env, v any, runErr error, inline bool) (db.RunFinish, *db.RunCommit, bool) {
	f := db.RunFinish{ActiveMS: env.Meter.ActiveMS()}
	jerr := env.Journal.Err()
	if runErr == nil && jerr != nil {
		runErr = fmt.Errorf("writing the run's journal: %w", jerr)
		f.Status, f.ErrorKind, f.Error = db.RunFailed, db.ErrKindBackend, runErr.Error()
		return f, nil, false
	}
	if jerr != nil {
		e.logger.Printf("automations: run %d: writing its journal: %v", env.Run.ID, jerr)
	}
	if runErr == nil {
		f.Status, f.Summary = db.RunSucceeded, runSummary(env.Buffer, v)
		if env.DryRun {
			return f, nil, false
		}
		return f, env.Buffer.Commit(), false
	}
	end := classifyRunError(runErr)
	if end.status == db.RunCancelled && ctx.Err() != nil {
		end.status, end.kind, end.msg = db.RunFailed, db.ErrKindInterrupted, stoppedMessage(inline)
	}
	f.Status, f.ErrorKind, f.Error = end.status, end.kind, end.msg
	return f, nil, end.abandoned
}

// stoppedMessage is the error of a run whose executor's ctx ended under it.
func stoppedMessage(inline bool) string {
	if inline {
		return "the dry run was stopped before it finished"
	}
	return "the daemon stopped while the run was in flight"
}

// classifyRunError maps a sandbox error to the run's end (spec §7.8).
func classifyRunError(err error) *runEnd {
	var ri *RunInterrupted
	var se *ScriptError
	var pe *PreParseError
	switch {
	case errors.As(err, &ri):
		end := interruptEnd(ri.Reason)
		end.msg, end.abandoned = ri.Error(), ri.Abandoned
		return end
	case errors.As(err, &se) && se.Name == ErrNamePermissionDenied:
		return failedEnd(db.ErrKindPermission, err)
	case errors.As(err, &se), errors.As(err, &pe):
		return failedEnd(db.ErrKindScript, err)
	default:
		return failedEnd(db.ErrKindBackend, err)
	}
}

func interruptEnd(r InterruptReason) *runEnd {
	switch r {
	case InterruptTimeout:
		return &runEnd{status: db.RunTimedOut, kind: db.ErrKindTimeout}
	case InterruptBudget:
		return &runEnd{status: db.RunBudgetExceeded, kind: db.ErrKindBudget}
	case InterruptExpired:
		return &runEnd{status: db.RunExpired, kind: db.ErrKindExpired}
	default:
		return &runEnd{status: db.RunCancelled, kind: db.ErrKindCancelled}
	}
}

// runSummary is the last output.report title, else the returned value as
// text (marshalForStep: a string as is, anything else as JSON, nothing for no
// value), clipped to SummaryClipBytes.
func runSummary(b *CommitBuffer, returned any) string {
	outs := b.Outputs()
	for i := len(outs) - 1; i >= 0; i-- {
		if outs[i].Kind == outputKindReport {
			return clipUTF8(outs[i].Title, SummaryClipBytes)
		}
	}
	return clipUTF8(marshalForStep(returned), SummaryClipBytes)
}

// finish writes the run's terminal status (and commit). A run already ended
// by someone else (a CLI cancel, the stale-dry-run sweep) refuses with
// ErrRunNotActive: that is the expected end of a cancelled run, not an
// error. An abandoned script disables its automation.
func (e *Executor) finish(runID int64, a *db.Automation, f db.RunFinish, commit *db.RunCommit, abandoned bool) {
	now := e.clock.Now()
	f.Now = now
	if abandoned {
		f.Error += "; the automation was disabled: " + runawayDisabledReason
	}
	err := e.db.FinishAutomationRun(runID, f, commit)
	switch {
	case errors.Is(err, db.ErrAutomationRunNotFound):
		return // deleted with its workbench meanwhile (runGone): nothing to record or disable
	case errors.Is(err, db.ErrRunNotActive):
		// Ended by someone else; still record the active time measured here.
		if f.ActiveMS > 0 {
			if err := e.db.AddAutomationRunUsage(runID, db.RunUsage{ActiveMS: f.ActiveMS}); err != nil {
				e.logger.Printf("automations: run %d: recording its active time: %v", runID, err)
			}
		}
	case err != nil:
		e.logger.Printf("automations: run %d: finishing as %s: %v", runID, f.Status, err)
	}
	if !abandoned {
		return
	}
	e.logger.Printf("automations: run %d of %q: its script did not stop after the interrupt and was abandoned; automation disabled (%s)",
		runID, a.Slug, runawayDisabledReason)
	if err := e.db.SetAutomationEnabled(a.ID, false, now); err != nil {
		e.logger.Printf("automations: disabling runaway automation %q: %v", a.Slug, err)
	}
}
