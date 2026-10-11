package digest

import (
	"os/exec"
	"slices"
	"strings"
	"syscall"
)

// IsolateChild prepares a CLI generator's subprocess for a caller on a
// hook's budget (the Stop ask guard): the child gets its own process group,
// and cancelling it — the caller's budget or a signal it caught — kills that
// whole group at once rather than sending the child alone an interrupt, so
// nothing the CLI started outlives the call; ReapChild after the wait kills
// whatever of the group is still left. Every variable named in dropEnv is
// removed from cmd.Env (set it first).
func IsolateChild(cmd *exec.Cmd, dropEnv []string) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	if len(dropEnv) == 0 {
		return
	}
	env := cmd.Env[:0:0]
	for _, e := range cmd.Env {
		name, _, _ := strings.Cut(e, "=")
		if !slices.Contains(dropEnv, name) {
			env = append(env, e)
		}
	}
	cmd.Env = env
}

// ReapChild kills what is left of an isolated child's process group after
// its wait returned; a group already gone is no error.
func ReapChild(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}
