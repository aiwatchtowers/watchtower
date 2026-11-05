package agentreport

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

// overloaded reports the 1-minute load average when it is above the CPU
// count: more runnable work than cores, so a wall-clock budget measures the
// scheduler rather than the code. ok is false when the machine is not
// overloaded or the load cannot be read (then the budget is judged).
func overloaded() (load float64, ok bool) {
	var raw string
	switch runtime.GOOS {
	case "linux":
		b, err := os.ReadFile("/proc/loadavg")
		if err != nil {
			return 0, false
		}
		raw = string(b)
	case "darwin":
		b, err := exec.Command("/usr/sbin/sysctl", "-n", "vm.loadavg").Output() // "{ 1.23 4.56 7.89 }"
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
