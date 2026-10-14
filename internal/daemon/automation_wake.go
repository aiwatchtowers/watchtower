package daemon

import (
	"context"
	"os"
	"os/signal"
	gosync "sync"
	"syscall"
)

// AutomationWakeSignal asks a running daemon to tick the automations
// scheduler and poll the executor now (spec 2026-10-14 §20 D1): the CLI sends
// it after `automations run`, a recipe save or an approval. It never starts a
// sync — TriggerSignal (SIGUSR1) keeps meaning that.
const AutomationWakeSignal = syscall.SIGUSR2

// AutomationRunner is a daemon-owned automations loop: the scheduler or the
// executor (*automations.Scheduler, *automations.Executor). Run blocks until
// ctx is done and returns only once its own goroutines have ended; Wake never
// blocks.
type AutomationRunner interface {
	Run(ctx context.Context) error
	Wake()
}

// SetAutomations attaches the automations scheduler and executor. Run starts
// both when both are set and automations.enabled is on, and forwards every
// AutomationWakeSignal to both.
func (d *Daemon) SetAutomations(scheduler, executor AutomationRunner) {
	d.automationScheduler = scheduler
	d.automationExecutor = executor
}

// WatchAutomationWake returns a channel that fires once per
// AutomationWakeSignal received — the WatchTrigger contract: non-blocking
// sends, so a burst collapses into the one wake already queued, and the
// channel is closed once ctx is done.
func WatchAutomationWake(ctx context.Context) <-chan struct{} {
	ch := make(chan struct{}, 1)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, AutomationWakeSignal)
	go func() {
		defer signal.Stop(sigCh)
		defer close(ch)
		for {
			select {
			case <-ctx.Done():
				return
			case <-sigCh:
				select {
				case ch <- struct{}{}:
				default:
				}
			}
		}
	}()
	return ch
}

// watchAutomationWake installs the AutomationWakeSignal watcher unless a test
// injected its own channel. It is installed even with automations off (a wake
// is then dropped): SIGUSR2's default action would terminate the daemon.
func (d *Daemon) watchAutomationWake(ctx context.Context) {
	if d.automationWakeCh == nil {
		d.automationWakeCh = WatchAutomationWake(ctx)
	}
}

// startAutomations starts the scheduler, the executor and the wake forwarder
// as goroutines of their own — never inside the sync loop, so a wake is
// served while a sync runs and never triggers one. With automations.enabled
// off (FEAT-01) or nothing wired it starts nothing. The returned stop cancels
// them and waits until all three have returned (the executor finishes or
// interrupts its in-flight runs first), so no goroutine outlives Run.
func (d *Daemon) startAutomations(ctx context.Context) (stop func()) {
	if d.automationScheduler == nil || d.automationExecutor == nil {
		return func() {}
	}
	if !d.config.Automations.Enabled {
		d.logger.Println("automations: disabled (automations.enabled=false), scheduler and executor not started")
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	var wg gosync.WaitGroup
	for name, r := range map[string]AutomationRunner{"scheduler": d.automationScheduler, "executor": d.automationExecutor} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.Run(runCtx); err != nil {
				d.logger.Printf("automations: %s stopped: %v", name, err)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		d.forwardAutomationWakes(runCtx)
	}()
	d.logger.Println("automations: scheduler and executor started")
	return func() {
		cancel()
		wg.Wait()
	}
}

// forwardAutomationWakes hands every wake to both runners until ctx is done
// or the wake channel closes.
func (d *Daemon) forwardAutomationWakes(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-d.automationWakeCh:
			if !ok {
				return
			}
			d.automationScheduler.Wake()
			d.automationExecutor.Wake()
		}
	}
}
