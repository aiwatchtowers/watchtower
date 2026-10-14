package cmd

import (
	"errors"
	"fmt"
	"syscall"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
)

// errDaemonCannotWake is wakeAutomations' answer for a running daemon that
// does not advertise daemon.AutomationWakeCapability: one built before
// automations, or one started while automations were off. Either would
// silently ignore SIGUSR2 and the run would just wait for its next poll, so
// the CLI does not signal it and tells the owner to restart it instead.
var errDaemonCannotWake = errors.New("the running daemon is older, or was started with automations off, and can't be woken; " +
	"restart it (`watchtower sync stop`, then `watchtower sync --daemon --detach`) — the run starts on its next poll")

// automationsOffWakeNote is what wake prints with automations.enabled off:
// the daemon runs no scheduler or executor, so there is nothing to wake, and
// enabling the feature cancels the runs queued meanwhile (FEAT-03 hook).
const automationsOffWakeNote = "automations are turned off in Settings → Features; the daemon was not woken — " +
	"a queued run stays queued and is cancelled when you turn them on"

// wakeAutomations sends the daemon its automation wake signal (SIGUSR2,
// spec §7.4), so the scheduler rescans and the executor polls now. No
// daemon → (false, nil): a queued run simply starts when one does. A daemon
// that does not advertise the wake capability beside its PID file is never
// signalled → (false, errDaemonCannotWake). A pid whose identity cannot be
// confirmed is never signalled either. P3's Desktop wake and P5's
// session-launched/session-ended call it.
func wakeAutomations(cfg *config.Config) (running bool, err error) {
	pidPath := pidFilePath(cfg)
	pid, err := daemon.FindConfirmedProcess(pidPath)
	if err != nil {
		if errors.Is(err, daemon.ErrIdentityUnconfirmed) {
			return false, fmt.Errorf("cannot confirm PID %d is the watchtower daemon; refusing to signal it — check manually, e.g. `ps -p %d`", pid, pid)
		}
		return false, fmt.Errorf("reading pid file: %w", err)
	}
	if pid == 0 {
		return false, nil
	}
	capable, err := daemon.HasCapability(pidPath, pid, daemon.AutomationWakeCapability)
	if err != nil {
		return false, err
	}
	if !capable {
		return false, errDaemonCannotWake
	}
	if err := syscall.Kill(pid, daemon.AutomationWakeSignal); err != nil {
		return false, fmt.Errorf("waking the daemon (PID %d): %w", pid, err)
	}
	return true, nil
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
	if !cfg.Automations.Enabled {
		fmt.Fprintln(cmd.OutOrStdout(), automationsOffWakeNote)
		return nil
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
