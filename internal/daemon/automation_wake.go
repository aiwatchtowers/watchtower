package daemon

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/signal"
	"strconv"
	"strings"
	gosync "sync"
	"syscall"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/fsutil"
)

// AutomationWakeSignal asks a running daemon to tick the automations
// scheduler and poll the executor now (spec 2026-10-14 §20 D1): the CLI sends
// it after `automations run`, a recipe save or an approval. Every one also
// ticks the Watchman twin's wake (WatchmanWakeCapability): a wait point of an
// armed session sends it after queueing its item. It never starts a sync —
// TriggerSignal (SIGUSR1) keeps meaning that.
const AutomationWakeSignal = syscall.SIGUSR2

// AutomationWakeCapability is the line a daemon whose scheduler and executor
// serve AutomationWakeSignal writes into its capabilities file: it tells the
// CLI whether this daemon actually runs the automations wake. A daemon built
// before automations, or one that wired none (the upgrade step failed closed), silently ignores
// SIGUSR2 (the Go runtime catches it and does nothing), so a run would just
// wait for the next poll; the CLI signals only a daemon that advertises this
// and otherwise says so.
const AutomationWakeCapability = "automations-wake"

// WatchmanWakeCapability is the capabilities-file line of a daemon whose
// AutomationWakeSignal also wakes the Watchman twin (spec
// 2026-11-16-watchman-design §4): every daemon that writes the file. A wait
// point signals only a daemon that advertises it; an older one would take the
// signal for an automations wake alone, and the item waits for the next
// cycle's scan.
const WatchmanWakeCapability = "watchman-wake"

// CapsPath is the capabilities file beside a daemon's PID file: its first
// line is the daemon's pid, each further line one capability.
func CapsPath(pidPath string) string { return pidPath + ".caps" }

// writeCaps writes this process's capabilities file beside pidPath, one
// line per capability.
func writeCaps(pidPath string, caps []string) error {
	body := strconv.Itoa(os.Getpid()) + "\n"
	for _, c := range caps {
		body += c + "\n"
	}
	if err := fsutil.WriteFileAtomic(CapsPath(pidPath), []byte(body), 0o600); err != nil {
		return fmt.Errorf("writing capabilities file: %w", err)
	}
	return nil
}

// removeCaps removes the capabilities file; a missing one is fine.
func removeCaps(pidPath string) {
	if err := os.Remove(CapsPath(pidPath)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "warning: removing capabilities file: %v\n", err)
	}
}

// advertiseCaps writes the capabilities file beside the PID file and returns
// its removal: WatchmanWakeCapability always, AutomationWakeCapability only
// while automationsActive (otherwise the CLI never signals this daemon for
// an automation), SessionMessagesWakeCapability only with a message
// deliverer. A failed write is logged, not fatal: the daemon runs, the CLI
// just never wakes it.
func (d *Daemon) advertiseCaps() (remove func()) {
	caps := []string{WatchmanWakeCapability}
	if d.automationsActive() {
		caps = append([]string{AutomationWakeCapability}, caps...)
	}
	if d.messages != nil {
		caps = append(caps, SessionMessagesWakeCapability)
	}
	if err := writeCaps(d.pidPath, caps); err != nil {
		d.logger.Printf("daemon: %v (the CLI will not wake this daemon)", err)
		return func() {}
	}
	return func() { removeCaps(d.pidPath) }
}

// HasCapability reports whether daemon pid advertised capability in the
// capabilities file beside pidPath. A missing file, or one naming another
// pid (left by an earlier daemon), advertises nothing.
func HasCapability(pidPath string, pid int, capability string) (bool, error) {
	data, err := os.ReadFile(CapsPath(pidPath))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading capabilities file: %w", err)
	}
	sc := bufio.NewScanner(strings.NewReader(string(data)))
	if !sc.Scan() || strings.TrimSpace(sc.Text()) != strconv.Itoa(pid) {
		return false, nil
	}
	for sc.Scan() {
		if strings.TrimSpace(sc.Text()) == capability {
			return true, nil
		}
	}
	return false, nil
}

// AutomationRunner is a daemon-owned automations loop: the scheduler or the
// executor (*automations.Scheduler, *automations.Executor). Run blocks until
// ctx is done and returns only once its own goroutines have ended; Wake never
// blocks.
type AutomationRunner interface {
	Run(ctx context.Context) error
	Wake()
}

// SetAutomations attaches the automations scheduler and executor. Run starts
// both when both are set, and forwards every AutomationWakeSignal to both.
func (d *Daemon) SetAutomations(scheduler, executor AutomationRunner) {
	d.automationScheduler = scheduler
	d.automationExecutor = executor
}

// WatchAutomationWake returns a channel that fires once per
// AutomationWakeSignal received — the WatchTrigger contract: non-blocking
// sends, so a burst collapses into the one wake already queued, and the
// channel is closed once ctx is done.
//
// At ctx.Done the signal is ignored (signal.Ignore), not handed back to its
// default disposition (signal.Stop): the daemon's capabilities file still
// advertises the wake until Run's deferred cleanup removes it, and a CLI
// that read it in that window gets an explicit no-op from a daemon that is
// shutting down (a Go process ignores an unwatched SIGUSR2 anyway; this keeps
// that from depending on the runtime's default). It stays ignored until process exit, or until a later
// WatchAutomationWake re-enables it.
func WatchAutomationWake(ctx context.Context) <-chan struct{} {
	ch := make(chan struct{}, 1)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, AutomationWakeSignal)
	go func() {
		// Deferred last so it runs first: the signal is ignored before the
		// close tells a reader the watcher is done.
		defer close(ch)
		defer signal.Ignore(AutomationWakeSignal)
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
// injected its own channel. It is installed even with automations not wired
// (the upgrade step failed closed, cmd/automations_upgrade.go); a wake is then
// dropped (and the daemon does not advertise it, see advertiseCaps).
func (d *Daemon) watchAutomationWake(ctx context.Context) {
	if d.automationWakeCh == nil {
		d.automationWakeCh = WatchAutomationWake(ctx)
	}
}

// wakeAutomationExecutor asks the in-process executor to poll now — the
// daemon's approval hook wake (builtin.Fire); a no-op with no executor wired.
func (d *Daemon) wakeAutomationExecutor() {
	if d.automationExecutor != nil {
		d.automationExecutor.Wake()
	}
}

// WakeAutomations is wakeAutomationExecutor for the daemon's tower commands
// (inbox.act's reply press, Run Now and reminder hook).
func (d *Daemon) WakeAutomations() { d.wakeAutomationExecutor() }

// installApprovalHook sets the database's approval hook to builtin.Fire with
// the in-process executor wake, replacing a hook a tool registry built during
// wiring may have set (cmd's SIGUSR2 wake, which would signal this process).
func (d *Daemon) installApprovalHook() {
	if d.db != nil {
		d.db.SetApprovalHook(builtin.ApprovalHook(d.db, d.wakeAutomationExecutor, d.logger.Printf))
	}
}

// automationsActive reports whether Run starts the scheduler and executor:
// both wired. Only then does the daemon advertise
// AutomationWakeCapability — a wake to a daemon with neither would be
// dropped, and the CLI should say so instead of claiming it woke something.
func (d *Daemon) automationsActive() bool {
	return d.automationScheduler != nil && d.automationExecutor != nil
}

// startAutomations starts the scheduler and the executor as goroutines of
// their own — never inside the sync loop, so a wake is served while a sync
// runs and never triggers one. With nothing wired it starts nothing. While
// sync is paused the scheduler is stopped (pause.go). The returned stop
// cancels them and waits until both have returned (the executor finishes or
// interrupts its in-flight runs first), so no goroutine outlives Run.
func (d *Daemon) startAutomations(ctx context.Context) (stop func()) {
	if !d.automationsActive() {
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	var wg gosync.WaitGroup
	// The scheduler runs only while sync is not paused (no scheduled run
	// starts); the executor always does (Run Now, approval apply).
	wg.Go(func() {
		d.runUnlessPaused(runCtx, "automations: scheduler", d.automationScheduler.Run)
	})
	wg.Go(func() {
		if err := d.automationExecutor.Run(runCtx); err != nil {
			d.logger.Printf("automations: executor stopped: %v", err)
		}
	})
	d.logger.Println("automations: scheduler and executor started")
	return func() {
		cancel()
		wg.Wait()
	}
}

// startWakeForwarder starts the goroutine that hands every
// AutomationWakeSignal to the automations runners (when active), the agent
// message deliverer (when wired) and the Watchman twin; the returned stop
// cancels it and waits for it.
func (d *Daemon) startWakeForwarder(ctx context.Context) (stop func()) {
	if d.watchmanWakeCh == nil {
		d.watchmanWakeCh = make(chan struct{}, 1)
	}
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.forwardWakes(runCtx)
	}()
	return func() {
		cancel()
		<-done
	}
}

// forwardWakes hands every wake to both automations runners (when active)
// and the agent message deliverer (when wired), and ticks the twin's
// channel — non-blocking, so a burst collapses into the tick already queued —
// until ctx is done or the wake channel closes.
func (d *Daemon) forwardWakes(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-d.automationWakeCh:
			if !ok {
				return
			}
			if d.automationsActive() {
				d.automationScheduler.Wake()
				d.automationExecutor.Wake()
			}
			d.wakeMessages()
			select {
			case d.watchmanWakeCh <- struct{}{}:
			default:
			}
		}
	}
}
