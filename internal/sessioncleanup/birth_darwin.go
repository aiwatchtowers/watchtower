package sessioncleanup

import (
	"syscall"
	"time"
)

// birthTime is path's birth time (darwin keeps it in Birthtimespec).
func birthTime(path string) (time.Time, bool) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return time.Time{}, false
	}
	return time.Unix(st.Birthtimespec.Sec, st.Birthtimespec.Nsec), true
}
