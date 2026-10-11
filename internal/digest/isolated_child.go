package digest

import (
	"errors"
	"os"
	"os/exec"
	"slices"
	"strings"
	"syscall"
)

// IsolateChild prepares a CLI generator's subprocess for a caller on a
// hook's budget (the Stop ask guard): the child gets its own process group,
// and cancelling it — the caller's budget or a signal it caught — kills that
// whole group at once rather than sending the child alone an interrupt, so
// nothing the CLI started outlives a cancelled call. The cancel first asks
// whether the child was already waited for (a zero signal answering
// os.ErrProcessDone): then it returns that and kills nothing, since the
// reaped child's pid, and so the group id, may already belong to another
// process. Every variable named in dropEnv is removed from the child's
// environment (cmd.Env, or this process's environment when cmd.Env is nil).
func IsolateChild(cmd *exec.Cmd, dropEnv []string) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if err := cmd.Process.Signal(syscall.Signal(0)); errors.Is(err, os.ErrProcessDone) {
			return err
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	if len(dropEnv) == 0 {
		return
	}
	src := cmd.Env
	if src == nil {
		src = os.Environ()
	}
	env := make([]string, 0, len(src))
	for _, e := range src {
		name, _, _ := strings.Cut(e, "=")
		if !slices.Contains(dropEnv, name) {
			env = append(env, e)
		}
	}
	cmd.Env = env
}
