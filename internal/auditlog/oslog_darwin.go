package auditlog

/*
#include <os/log.h>
#include <stdlib.h>

// %{public}s: the line carries no content, and without it the system log
// stores <private> in place of the line.
static void wt_audit(os_log_t l, const char *s) { os_log(l, "%{public}s", s); }
*/
import "C"

import (
	"sync"
	"unsafe"
)

var (
	logOnce sync.Once
	logger  C.os_log_t
)

// osLog writes line at the default level, which the system log persists
// without a logging profile.
func osLog(line string) {
	logOnce.Do(func() {
		// The two names stay allocated for the process's life: the handle
		// is created once and may keep pointing at them.
		logger = C.os_log_create(C.CString("com.watchtower.audit"), C.CString("read"))
	})
	cs := C.CString(line)
	C.wt_audit(logger, cs)
	C.free(unsafe.Pointer(cs))
}
