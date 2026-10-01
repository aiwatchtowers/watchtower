//go:build darwin

package extract

import (
	"errors"

	"golang.org/x/sys/unix"
)

// <sys/resource.h>: setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)
// puts a process in the background band — low CPU priority, throttled
// disk and network I/O — the band `taskpolicy -b` uses. x/sys does not
// export the constants.
const (
	prioDarwinProcess = 4
	prioDarwinBG      = 0x1000
)

// setBackgroundPriority moves process pid into the background band. A
// process that already exited (ESRCH) has nothing left to lower.
func setBackgroundPriority(pid int) error {
	err := unix.Setpriority(prioDarwinProcess, pid, prioDarwinBG)
	if errors.Is(err, unix.ESRCH) {
		return nil
	}
	return err
}
