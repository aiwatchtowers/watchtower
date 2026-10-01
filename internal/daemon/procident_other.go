//go:build !darwin

package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// readProcessIdentityOS is the portable fallback used on any OS without a
// dedicated reader. Watchtower ships a daemon only for macOS
// (procident_darwin.go); this path exists purely so `go build`/`go test`
// still succeed elsewhere (this repo's own CI runs `go test`/lint on
// ubuntu-latest). It shells out to `ps` for both the start time and the
// command name, forcing LC_ALL=C so the locale-formatted `lstart` string is
// always in the fixed layout below regardless of the calling environment —
// an un-forced `ps` call inherits the caller's locale (ru_RU, en_GB, ...)
// and fails to parse, which is exactly the bug this package used to have.
//
// Known limitation: `lstart` is a local wall-clock string with no UTC
// offset, so a process that started during a repeated local hour (a
// "fall back" DST transition) can be misread by up to one hour — the
// darwin reader avoids this entirely by reading an epoch-relative
// struct timeval instead of a formatted string. Since no real watchtower
// daemon runs this reader, this only affects test assertions executed
// under GOOS != darwin, never production behavior.
func readProcessIdentityOS(pid int) (processIdentity, error) {
	start, err := psStartTime(pid)
	if err != nil {
		return processIdentity{}, err
	}
	return processIdentity{startTime: start, comm: psComm(pid)}, nil
}

func psStartTime(pid int) (time.Time, error) {
	out, err := runPSLocaleIndependent(pid, "lstart=")
	if err != nil {
		return time.Time{}, err
	}
	if out == "" {
		return time.Time{}, fmt.Errorf("no lstart output for pid %d", pid)
	}
	return time.ParseInLocation("Mon Jan _2 15:04:05 2006", out, time.Local)
}

// psComm reads the process's command name, best-effort: an empty return
// (any lookup failure) means identifyProcess skips the comm factor rather
// than failing an otherwise-verified identity over a second-factor-only
// signal.
func psComm(pid int) string {
	out, err := runPSLocaleIndependent(pid, "comm=")
	if err != nil {
		return ""
	}
	return out
}

func runPSLocaleIndependent(pid int, format string) (string, error) {
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", format)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
