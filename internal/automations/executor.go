package automations

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/db"
)

// maxAbandonedRuns is how many abandoned script goroutines (AbandonedRuns)
// make the executor stop claiming: each one still burns a CPU, so past this
// many no new run starts until they end.
const maxAbandonedRuns = 2

// runawayDisabledReason is what the executor writes on a run whose script
// goroutine it had to abandon, after disabling the automation.
const runawayDisabledReason = "runaway script — check and re-enable"

// ErrRunNotClaimed is what ExecuteInline returns when its run could not be
// claimed: it is no longer queued, or its automation is at its concurrency.
var ErrRunNotClaimed = errors.New("automation run could not be claimed")

// ErrRecipeChanged is what ExecuteInlinePinned returns when the automation's
// approval hash is no longer the one its caller checked; the run was
// cancelled, never claimed.
var ErrRecipeChanged = errors.New("the recipe changed since it was checked")

// ExecutorOptions tunes NewExecutor.
type ExecutorOptions struct {
	// MaxConcurrent is how many runs may be running at once across every
	// automation (waiting runs do not count); ≤ 0 = MaxConcurrentRuns.
	MaxConcurrent int
	// Modules builds each run's SDK; nil = DefaultModules.
	Modules func(b Backends) []Module
	// Logger receives the executor's errors and notices; nil = log.Default().
	Logger *log.Logger
}

// Executor claims queued runs and executes them (spec §7.3): it cancels a
// queued run of a non-runnable automation, claims under the per-automation
// concurrency and MaxConcurrent, runs the claimed recipe snapshot in a fresh
// sandbox, and commits state and outputs only with a succeeded run (AUTO-04).
type Executor struct {
	db            *db.DB
	b             Backends
	clock         Clock
	maxConcurrent int
	modules       func(Backends) []Module
	logger        *log.Logger
	// abandoned counts abandoned script goroutines (AbandonedRuns); tests
	// replace it.
	abandoned func() int
	// finishPause waits before finish attempt n+1 (finishRetryPause; tests
	// replace it).
	finishPause func(ctx context.Context, attempt int)

	gated atomic.Bool // claims refused for abandoned goroutines (logged once per change)
	// readyWaits counts waits whose ready check passed and that wait for a
	// running slot: resumes take priority, so Step leaves them those slots.
	readyWaits atomic.Int64
	wakeCh     chan struct{}
	nudgeMu    sync.Mutex
	nudge      chan struct{} // closed and replaced by every Wake
	wg         sync.WaitGroup
}

// NewExecutor returns an executor over d. b.Clock defaults to RealClock and
// b.DB to d.
func NewExecutor(d *db.DB, b Backends, opts ExecutorOptions) *Executor {
	if b.Clock == nil {
		b.Clock = RealClock{}
	}
	if b.DB == nil {
		b.DB = d
	}
	e := &Executor{
		db: d, b: b, clock: b.Clock, maxConcurrent: opts.MaxConcurrent,
		modules: opts.Modules, logger: opts.Logger, abandoned: AbandonedRuns, finishPause: finishRetryPause,
		wakeCh: make(chan struct{}, 1), nudge: make(chan struct{}),
	}
	if e.maxConcurrent <= 0 {
		e.maxConcurrent = MaxConcurrentRuns
	}
	if e.modules == nil {
		e.modules = DefaultModules
	}
	if e.logger == nil {
		e.logger = log.Default()
	}
	return e
}

// Wake asks Run for a poll now and makes every in-flight run and wait
// re-read its status (a CLI cancel, an answered ask). It never blocks.
func (e *Executor) Wake() {
	select {
	case e.wakeCh <- struct{}{}:
	default:
	}
	e.nudgeMu.Lock()
	close(e.nudge)
	e.nudge = make(chan struct{})
	e.nudgeMu.Unlock()
}

// nudged is closed by the next Wake. Take it before reading a status, so a
// Wake after the read is never missed.
func (e *Executor) nudged() <-chan struct{} {
	e.nudgeMu.Lock()
	defer e.nudgeMu.Unlock()
	return e.nudge
}

// Wait blocks until every run goroutine Step started has finished.
func (e *Executor) Wait() { e.wg.Wait() }

// Run first ends the runs a previous daemon left running or waiting
// (failed/interrupted, AUTO-08; a live CLI dry run is spared) and withdraws
// their open asks (sweepAsks), then polls
// every PollInterval and on Wake until ctx is done. In-flight runs are
// interrupted with ctx and finished before Run returns nil.
func (e *Executor) Run(ctx context.Context) error {
	defer e.Wait()
	if !e.markInterrupted(ctx) {
		return nil
	}
	if err := e.sweepAsks(); err != nil {
		e.logger.Printf("automations: executor start: %v", err)
	}
	for ctx.Err() == nil {
		if _, err := e.Step(ctx); err != nil && ctx.Err() == nil {
			e.logger.Printf("automations: executor poll: %v", err)
		}
		select {
		case <-ctx.Done():
		case <-e.clock.After(PollInterval):
		case <-e.wakeCh:
		}
	}
	return nil
}

// markInterrupted retries MarkInterruptedAutomationRuns every PollInterval
// until it succeeds (nothing is claimed before it does); false when ctx ended
// first.
func (e *Executor) markInterrupted(ctx context.Context) bool {
	for {
		n, err := e.db.MarkInterruptedAutomationRuns(e.clock.Now())
		if err == nil {
			if n > 0 {
				e.logger.Printf("automations: %d run(s) left by the previous daemon ended as interrupted", n)
			}
			return true
		}
		e.logger.Printf("automations: executor start: %v (retrying)", err)
		select {
		case <-ctx.Done():
			return false
		case <-e.clock.After(PollInterval):
		}
	}
}

// Step is one poll (the test seam): it ends dry runs whose CLI died,
// withdraws the open asks of ended runs (sweepAsks), cancels
// queued runs of non-runnable automations, and claims queued runs oldest
// first while running runs are fewer than MaxConcurrent, starting one
// goroutine per claim. It claims nothing while AbandonedRuns() ≥ 2 (but
// still cancels non-runnable queued runs). Every
// failure is returned, joined; one run's failure does not stop the others.
func (e *Executor) Step(ctx context.Context) (started int, err error) {
	now := e.clock.Now()
	var errs []error
	if n, err := e.db.MarkStaleDryRuns(now); err != nil {
		errs = append(errs, err)
	} else if n > 0 {
		e.logger.Printf("automations: %d dry run(s) past their deadline ended (their CLI process stopped)", n)
	}
	if err := e.sweepAsks(); err != nil {
		errs = append(errs, err)
	}
	gated := e.claimsGated()
	queued, err := e.db.NextQueuedAutomationRuns(0)
	if err != nil {
		return 0, errors.Join(append(errs, err)...)
	}
	free := 0
	if !gated {
		if free, err = e.freeSlots(); err != nil {
			return 0, errors.Join(append(errs, err)...)
		}
	}
	p := poll{e: e, ctx: ctx, now: now, free: free, autos: map[int64]*db.Automation{}}
	for _, r := range queued {
		if ctx.Err() != nil {
			break
		}
		if err := p.consider(r); err != nil {
			errs = append(errs, fmt.Errorf("automation run %d: %w", r.ID, err))
		}
	}
	return p.started, errors.Join(errs...)
}

// sweepAsks withdraws (agent) the open asks of runs that ended: no run waits
// for them any more (a daemon restart, a cancel racing ask()'s insert, a
// withdraw that failed when the wait ended).
func (e *Executor) sweepAsks() error {
	n, err := e.db.WithdrawAsksOfEndedAutomationRuns()
	if n > 0 {
		e.logger.Printf("automations: withdrew %d open ask(s) of ended runs", n)
	}
	return err
}

// claimsGated reports whether AbandonedRuns() ≥ maxAbandonedRuns (no claim;
// queued runs of non-runnable automations are still cancelled). The change
// into and out of that state is logged once each.
func (e *Executor) claimsGated() bool {
	n := e.abandoned()
	gated := n >= maxAbandonedRuns
	if e.gated.Swap(gated) == gated {
		return gated
	}
	if gated {
		e.logger.Printf("automations: %d abandoned script goroutines still running; no run is claimed until fewer than %d remain",
			n, maxAbandonedRuns)
	} else {
		e.logger.Printf("automations: abandoned script goroutines down to %d; claiming again", n)
	}
	return gated
}

// freeSlots is MaxConcurrent minus the runs in status running (waiting runs
// hold no slot) and minus the ready waits about to resume (they go first).
func (e *Executor) freeSlots() (int, error) {
	active, err := e.db.ListActiveAutomationRuns()
	if err != nil {
		return 0, err
	}
	running := 0
	for _, r := range active {
		if r.Status == db.RunRunning {
			running++
		}
	}
	return e.maxConcurrent - running - int(e.readyWaits.Load()), nil
}

// poll is one Step's walk over the queued runs.
type poll struct {
	e       *Executor
	ctx     context.Context
	now     time.Time
	free    int
	started int
	autos   map[int64]*db.Automation
}

// consider cancels r when its automation is not runnable, else claims and
// starts it when a slot is free.
func (p *poll) consider(r db.AutomationRun) error {
	a, ok := p.autos[r.AutomationID]
	if !ok {
		got, err := p.e.db.GetAutomation(r.AutomationID)
		if err != nil {
			return err
		}
		a, p.autos[r.AutomationID] = got, got
	}
	if !a.Runnable() {
		return p.e.cancelNotRunnable(r.ID, p.now)
	}
	if p.free <= 0 {
		return nil
	}
	claimed, err := p.e.claim(r.ID, a, p.now, p.e.maxConcurrent)
	if err != nil || !claimed {
		return err // not claimed: another executor won, or the automation is at its concurrency
	}
	p.free--
	p.started++
	p.e.wg.Go(func() {
		p.e.runClaimed(p.ctx, r.ID, a, false)
	})
	return nil
}

// cancelNotRunnable ends a queued run of a non-runnable automation. A run
// claimed or ended meanwhile (ErrRunNotQueued) is not an error: whoever
// moved it owns it now.
func (e *Executor) cancelNotRunnable(runID int64, now time.Time) error {
	if err := e.db.CancelQueuedNotRunnable(runID, now); err != nil && !errors.Is(err, db.ErrRunNotQueued) {
		return err
	}
	return nil
}

// claim moves the run to running with a snapshot of a's indexed recipe and
// budgets; the run executes that snapshot, never the file (AUTO-06). The
// daemon's claims pass maxRunning (the global running bound is part of the
// claim's UPDATE); ExecuteInline's dry-run claim passes 0 (no global bound).
func (e *Executor) claim(runID int64, a *db.Automation, now time.Time, maxRunning int) (bool, error) {
	return e.db.ClaimAutomationRunWithin(runID, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes,
		maxRunning, now)
}

// ExecuteInline claims run runID and executes it in the caller's goroutine
// (the CLI's dry-run, which the daemon never picks up), then returns the
// finished row. A dry run is claimed even when its automation is not
// runnable (AUTO-06's dry-run exemption; a recipe that does not parse ends
// failed/not_runnable); any other trigger of a non-runnable automation is
// cancelled as not_runnable instead. ErrRunNotClaimed when the claim lost.
func (e *Executor) ExecuteInline(ctx context.Context, runID int64) (*db.AutomationRun, error) {
	return e.ExecuteInlinePinned(ctx, runID, "")
}

// ExecuteInlinePinned is ExecuteInline for a caller that gated the run on the
// recipe it checked at approvalHash ("" = no pin) — the CLI's dry run, whose
// D16 gate (ask #271) looked at the recipe's confirmation before queueing.
// The automation row is read once here and the claim snapshots exactly that
// row's recipe, so when its approval_hash is no longer approvalHash (a rescan
// between the caller's check and the claim) the queued run is cancelled,
// never claimed, and ErrRecipeChanged is returned.
func (e *Executor) ExecuteInlinePinned(ctx context.Context, runID int64, approvalHash string) (*db.AutomationRun, error) {
	run, err := e.db.GetAutomationRun(runID)
	if err != nil {
		return nil, err
	}
	a, err := e.db.GetAutomation(run.AutomationID)
	if err != nil {
		return nil, fmt.Errorf("automation run %d: %w", runID, err)
	}
	now := e.clock.Now()
	if approvalHash != "" && a.ApprovalHash != approvalHash {
		if _, err := e.db.CancelAutomationRun(runID, now); err != nil {
			return nil, fmt.Errorf("automation run %d: %w", runID, err)
		}
		return nil, fmt.Errorf("automation run %d: %w (approval hash %s, checked %s); check it again",
			runID, ErrRecipeChanged, a.ApprovalHash, approvalHash)
	}
	if run.Trigger != db.TriggerDryRun && !a.Runnable() {
		if err := e.cancelNotRunnable(runID, now); err != nil {
			return nil, fmt.Errorf("automation run %d: %w", runID, err)
		}
		return e.db.GetAutomationRun(runID)
	}
	claimed, err := e.claim(runID, a, now, 0)
	if err != nil {
		return nil, fmt.Errorf("automation run %d: %w", runID, err)
	}
	if !claimed {
		return nil, fmt.Errorf("automation run %d: %w", runID, ErrRunNotClaimed)
	}
	e.runClaimed(ctx, runID, a, true)
	return e.db.GetAutomationRun(runID)
}
