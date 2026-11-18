package cmd

import (
	"errors"
	"fmt"
	"os"
	"syscall"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
)

// errDaemonCannotWake is wakeAutomations' answer for a running daemon that
// does not advertise daemon.AutomationWakeCapability: one built before
// automations, or one whose start-up upgrade step failed (it then wires no
// automations, see pauseAutomationsTurnedOff). Either would
// silently ignore SIGUSR2 and the run would just wait for its next poll, so
// the CLI does not signal it and tells the owner to restart it instead.
var errDaemonCannotWake = errors.New("the running daemon is older, or could not start automations (see its log), and can't be woken; " +
	"restart it (`watchtower sync stop`, then `watchtower sync --daemon --detach`) — the run starts on its next poll")

// automationWakeKill sends the wake signal; tests count the signals sent
// instead of waiting to see none arrive.
var automationWakeKill = syscall.Kill

// wakeAutomations sends the daemon its automation wake signal (SIGUSR2,
// spec §7.4), so the scheduler rescans and the executor polls now. No
// daemon → (false, nil): a queued run simply starts when one does. A daemon
// that does not advertise the wake capability beside its PID file is never
// signalled → (false, errDaemonCannotWake). A pid whose identity cannot be
// confirmed is never signalled either. P3's Desktop wake and P5's
// session-launched/session-ended call it.
func wakeAutomations(cfg *config.Config) (running bool, err error) {
	running, capable, err := signalDaemonWake(cfg, daemon.AutomationWakeCapability)
	switch {
	case err != nil:
		return false, err
	case running && !capable:
		return false, errDaemonCannotWake
	}
	return running, nil
}

// wakeWatchman asks a running daemon to run the Watchman twin now, after a
// wait point queued an item (spec 2026-11-16-watchman-design §4). No daemon,
// or one that does not advertise daemon.WatchmanWakeCapability, is not
// signalled and is no error: the daemon's cycle scan picks the item up.
func wakeWatchman(cfg *config.Config) error {
	_, _, err := signalDaemonWake(cfg, daemon.WatchmanWakeCapability)
	return err
}

// watchmanWaitPointWake is the wake a wait point of an armed session sends
// after queueing its item; a failure is one stderr line (the cycle scan still
// picks the item up).
func watchmanWaitPointWake(cfg *config.Config) func() {
	return func() {
		if err := wakeWatchman(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "watchtower: the daemon was not woken for Watchman (it picks the item up at its next cycle): %v\n", err)
		}
	}
}

// signalDaemonWake sends daemon.AutomationWakeSignal to the running daemon
// when it advertises capability. running is false with no daemon; capable
// is whether it advertises capability (and so was signalled). A pid whose
// identity cannot be confirmed is never signalled.
func signalDaemonWake(cfg *config.Config, capability string) (running, capable bool, err error) {
	pidPath := pidFilePath(cfg)
	pid, err := daemon.FindConfirmedProcess(pidPath)
	if err != nil {
		if errors.Is(err, daemon.ErrIdentityUnconfirmed) {
			return false, false, fmt.Errorf("cannot confirm PID %d is the watchtower daemon; refusing to signal it — check manually, e.g. `ps -p %d`", pid, pid)
		}
		return false, false, fmt.Errorf("reading pid file: %w", err)
	}
	if pid == 0 {
		return false, false, nil
	}
	capable, err = daemon.HasCapability(pidPath, pid, capability)
	if err != nil || !capable {
		return true, false, err
	}
	if err := automationWakeKill(pid, daemon.AutomationWakeSignal); err != nil {
		return true, true, fmt.Errorf("waking the daemon (PID %d): %w", pid, err)
	}
	return true, true, nil
}

// daemonNotRunningNote is what run prints when no daemon is running.
const daemonNotRunningNote = "daemon not running; the run starts when it does"

// wakeNote is the line run/wake print after wakeAutomations returned
// (running, err): "" when the daemon was woken, the not-running or
// too-old-to-wake note, or a warning for any other failure. ok is false only
// for that last case.
func wakeNote(running bool, err error, notRunning string) (note string, ok bool) {
	switch {
	case errors.Is(err, errDaemonCannotWake):
		return err.Error(), true
	case err != nil:
		return "warning: the daemon was not woken: " + err.Error(), false
	case !running:
		return notRunning, true
	}
	return "", true
}

func runAutomationsWake(cmd *cobra.Command, _ []string) error {
	cfg, err := loadAutomationsConfig()
	if err != nil {
		return err
	}
	running, err := wakeAutomations(cfg)
	note, ok := wakeNote(running, err, "daemon not running")
	if !ok {
		return err
	}
	if note == "" {
		note = "Daemon woken."
	}
	fmt.Fprintln(cmd.OutOrStdout(), note)
	return nil
}
