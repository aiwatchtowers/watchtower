package agentreport

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// overloadCeiling bounds a budgeted run even on an overloaded machine,
// where the budget itself is not judged (seen: 6 s for a 1 s budget at load
// 365 on 8 CPUs).
const overloadCeiling = 10 * time.Second

// overloaded reports the 1-minute load average and whether it is above the
// CPU count: more runnable work than cores, so a wall-clock budget measures
// the scheduler rather than the code. over is false when the load cannot be
// read (then the budget is judged).
//
// Process CPU time (internal/confluenceedit's perf test) does not help here:
// that test judges a scaling ratio, while this one is an absolute budget, and
// on a saturated Mac the CPU time of the same run grew ~1.5x too (threads
// land on slower cores).
func overloaded() (load float64, over bool) {
	var raw string
	switch runtime.GOOS {
	case "linux":
		b, err := os.ReadFile("/proc/loadavg")
		if err != nil {
			return 0, false
		}
		raw = string(b)
	case "darwin":
		cmd := exec.Command("/usr/sbin/sysctl", "-n", "vm.loadavg") // "{ 1.23 4.56 7.89 }"
		cmd.Env = []string{"LC_ALL=C"}                              // a decimal point, whatever the owner's locale
		b, err := cmd.Output()
		if err != nil {
			return 0, false
		}
		raw = strings.TrimLeft(strings.TrimSpace(string(b)), "{ ")
	default:
		return 0, false
	}
	fields := strings.Fields(raw)
	if len(fields) == 0 {
		return 0, false
	}
	load, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return load, load > float64(runtime.NumCPU())
}
