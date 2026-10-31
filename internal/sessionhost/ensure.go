package sessionhost

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

// ensureWait bounds how long Ensure waits for a host it started to answer.
const ensureWait = 5 * time.Second

// ensurePoll is the dial retry interval while a started host comes up.
const ensurePoll = 50 * time.Millisecond

// Ensure makes sure a v2 host answers on socket. When nothing answers it
// starts `exe session-host --socket socket` detached (its own session, no
// terminal, stdio to /dev/null) and waits for it. A v1 host is never
// replaced: Ensure returns ErrHostV1 (and a started host would find the
// socket live and exit anyway).
func Ensure(ctx context.Context, socket, exe string) error {
	err := ping(ctx, socket)
	if err == nil || !nothingAnswers(err) {
		return err
	}
	cmd := exec.Command(exe, "session-host", "--socket", socket) // our own CLI binary
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start session host: %w", err)
	}
	go func() { _ = cmd.Wait() }() // reap the host whenever it exits

	ctx, cancel := context.WithTimeout(ctx, ensureWait)
	defer cancel()
	t := time.NewTicker(ensurePoll)
	defer t.Stop()
	for {
		err := ping(ctx, socket)
		if err == nil || !nothingAnswers(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("session host did not answer: %w", err)
		case <-t.C:
		}
	}
}

// ping dials and says Hello, then hangs up.
func ping(ctx context.Context, socket string) error {
	c, err := Dial(ctx, socket)
	if err != nil {
		return err
	}
	_ = c.Close()
	return nil
}

// nothingAnswers reports a dial error meaning no host serves the socket.
func nothingAnswers(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
}
