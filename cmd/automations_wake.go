package cmd

import (
	"errors"
	"fmt"
	"syscall"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
)

// wakeAutomations sends the daemon its automation wake signal (SIGUSR2,
// spec §7.4), so the scheduler rescans and the executor polls now. No
// daemon → (false, nil): a queued run simply starts when one does. A pid
// whose identity cannot be confirmed is never signalled. P3's Desktop wake,
// P5's session-launched/session-ended call it.
func wakeAutomations(cfg *config.Config) (running bool, err error) {
	pid, err := daemon.FindConfirmedProcess(pidFilePath(cfg))
	if err != nil {
		if errors.Is(err, daemon.ErrIdentityUnconfirmed) {
			return false, fmt.Errorf("cannot confirm PID %d is the watchtower daemon; refusing to signal it — check manually, e.g. `ps -p %d`", pid, pid)
		}
		return false, fmt.Errorf("reading pid file: %w", err)
	}
	if pid == 0 {
		return false, nil
	}
	if err := syscall.Kill(pid, daemon.AutomationWakeSignal); err != nil {
		return false, fmt.Errorf("waking the daemon (PID %d): %w", pid, err)
	}
	return true, nil
}

// daemonNotRunningNote is what run/wake print when no daemon is running.
const daemonNotRunningNote = "daemon not running; the run starts when it does"

func runAutomationsWake(cmd *cobra.Command, _ []string) error {
	cfg, err := loadAutomationsConfig()
	if err != nil {
		return err
	}
	running, err := wakeAutomations(cfg)
	if err != nil {
		return err
	}
	if !running {
		fmt.Fprintln(cmd.OutOrStdout(), "daemon not running")
		return nil
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Daemon woken.")
	return nil
}
