package media

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"watchtower/internal/extract"
)

// sipsPath is the macOS image tool (a var so tests run a stub).
var sipsPath = "/usr/bin/sips"

// sipsTimeout bounds one sips run on attacker bytes; sipsWaitDelay is how
// long Wait waits for the output pipes after the group is killed.
var (
	sipsTimeout   = 30 * time.Second
	sipsWaitDelay = 5 * time.Second
)

// runSips runs sips with args on in, writing to a fresh 0600 media-* file
// beside it, and returns that file. The helper runs in its own process group
// at nice 10; the deadline or a cancel kills the whole group. On any failure
// the output file is removed (never reused as input) and the error is a
// convertError (convert_failed), a timeout included.
func runSips(ctx context.Context, in string, args ...string) (string, error) {
	f, err := newTempFile(filepath.Dir(in), "*.jpg")
	if err != nil {
		return "", err
	}
	out := f.Name()
	_ = f.Close()
	ctx, cancel := context.WithTimeout(ctx, sipsTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, sipsPath, append(append([]string{}, args...), in, "--out", out)...)
	cmd.Dir = filepath.Dir(in)
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killGroup(cmd) }
	cmd.WaitDelay = sipsWaitDelay
	err = extract.RunHelper(cmd, func(string, ...any) {})
	if cmd.Process != nil {
		_ = killGroup(cmd) // sips is gone; anything it forked goes with it
	}
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	if err != nil {
		_ = os.Remove(out)
		if ctxErr := ctx.Err(); ctxErr != nil {
			err = ctxErr
		}
		return "", convertError{err}
	}
	return out, nil
}

// killGroup kills the command's whole process group (Setpgid: the child's
// pid is the group id); a group already gone is not an error.
func killGroup(cmd *exec.Cmd) error {
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}
