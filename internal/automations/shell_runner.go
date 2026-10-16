package automations

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"time"
	"unicode/utf8"
)

// MaxShellStreamBytes is how much of each of a shell() command's streams is
// kept: the last 256 KiB (spec §13.2); the rest is dropped and the stream
// marked truncated.
const MaxShellStreamBytes = 256 << 10

// shellPipeGrace bounds how long Wait waits for the command's pipes to close
// once its shell has exited (a background child still holding them) or its
// group was killed.
const shellPipeGrace = 2 * time.Second

// processShellRunner runs shell() commands as /bin/sh -c in a process group
// of their own.
type processShellRunner struct{}

// NewProcessShellRunner returns the ShellRunner of Backends.Shell: the
// command runs as `/bin/sh -c <cmd>` in c.Dir with exactly c.Env, in its own
// process group. When ctx ends or c.Deadline passes the whole group is
// killed (SIGKILL) and the call fails with ctx's error; the group is killed
// as well once the shell exits, so no background child outlives the call. A
// non-zero exit is a result, not an error.
func NewProcessShellRunner() ShellRunner { return processShellRunner{} }

func (processShellRunner) Run(ctx context.Context, c ShellCommand) (ShellResult, error) {
	if !c.Deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, c.Deadline)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", c.Cmd)
	cmd.Dir = c.Dir
	cmd.Env = append([]string{}, c.Env...) // never nil: nil would inherit the daemon's environment
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killGroup(cmd) }
	cmd.WaitDelay = shellPipeGrace
	stdout, stderr := &tailBuffer{max: MaxShellStreamBytes}, &tailBuffer{max: MaxShellStreamBytes}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	if err := cmd.Start(); err != nil {
		return ShellResult{}, fmt.Errorf("starting /bin/sh: %w", err)
	}
	waitErr := cmd.Wait()
	_ = killGroup(cmd) // the shell is gone; its background children go with it
	if err := ctx.Err(); err != nil {
		return ShellResult{}, err
	}
	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) && !errors.Is(waitErr, exec.ErrWaitDelay) {
		return ShellResult{}, fmt.Errorf("running /bin/sh: %w", waitErr)
	}
	return ShellResult{
		ExitCode: cmd.ProcessState.ExitCode(),
		Stdout:   stdout.String(), StdoutTruncated: stdout.cut,
		Stderr: stderr.String(), StderrTruncated: stderr.cut,
	}, nil
}

// killGroup kills the command's whole process group (Setpgid: the shell's
// pid is the group id). A group already gone is not an error.
func killGroup(cmd *exec.Cmd) error {
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}

// tailBuffer keeps the last max bytes written to it; cut reports that
// earlier bytes were dropped.
type tailBuffer struct {
	buf []byte
	max int
	cut bool
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if len(p) > b.max {
		b.cut = true
		p = p[len(p)-b.max:]
	}
	b.buf = append(b.buf, p...)
	if over := len(b.buf) - b.max; over > 0 {
		b.cut = true
		// Compact only past twice the cap, so a long stream costs one copy
		// per max bytes written, not one per write.
		if len(b.buf) >= 2*b.max {
			b.buf = append(b.buf[:0], b.buf[over:]...)
		}
	}
	return n, nil
}

// String is the kept tail; a cut tail starts on a UTF-8 boundary (the
// partial rune the cut left at its start is dropped).
func (b *tailBuffer) String() string {
	s := b.buf
	if over := len(s) - b.max; over > 0 {
		s = s[over:]
	}
	if b.cut {
		for i := 0; i < len(s) && i < utf8.UTFMax && !utf8.RuneStart(s[0]); i++ {
			s = s[1:]
		}
	}
	return string(s)
}
