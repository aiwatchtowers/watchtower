package extract

import (
	"errors"
	"os/exec"
	"strings"
	"syscall"
)

// helperNice is the nice value a helper subprocess runs at: extraction is
// batch work inside the daemon's sync cycle and yields the CPU to the
// owner's foreground apps. A plain nice value, not the macOS background
// band (PRIO_DARWIN_BG): that band also throttles disk I/O and starves its
// processes under load, and the helpers run under fixed timeouts.
const helperNice = 10

// runHelper runs a helper subprocess (the PDF parser, the OCR helper) like
// cmd.Run, but lowers its CPU priority to helperNice right after it starts.
// Failing to lower it is logged and the helper runs at its default
// priority; a helper that already exited (ESRCH) has nothing to lower.
func runHelper(cmd *exec.Cmd, logf logFunc) error {
	if err := cmd.Start(); err != nil {
		return err
	}
	err := syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, helperNice)
	if err != nil && !errors.Is(err, syscall.ESRCH) {
		logf("%s: lowering the helper's priority: %v", strings.Join(cmd.Args, " "), err)
	}
	return cmd.Wait()
}
