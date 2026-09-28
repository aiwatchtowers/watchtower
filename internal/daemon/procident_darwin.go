//go:build darwin

package daemon

import (
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// readProcessIdentityOS reads pid's actual start time and command name via
// kern.proc.pid — the BSD/Darwin kinfo_proc sysctl, a single syscall with no
// subprocess and no locale-dependent string to parse: p_starttime is a
// struct timeval (epoch-relative seconds+microseconds, so it also carries
// no local-wall-clock DST ambiguity), and p_comm is the kernel's own
// recorded process name (not merely argv[0], which a process can change).
// This is the reader watchtower actually ships and runs its daemon under;
// see procident_other.go for the portable (non-darwin, CI-only) fallback.
func readProcessIdentityOS(pid int) (processIdentity, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return processIdentity{}, err
	}

	start := time.Unix(info.Proc.P_starttime.Sec, int64(info.Proc.P_starttime.Usec)*1000)
	comm := nulTerminated(info.Proc.P_comm[:])
	return processIdentity{startTime: start, comm: comm}, nil
}

// nulTerminated trims a fixed-size, NUL-padded C string buffer to its
// content.
func nulTerminated(buf []byte) string {
	if i := strings.IndexByte(string(buf), 0); i >= 0 {
		return string(buf[:i])
	}
	return string(buf)
}
