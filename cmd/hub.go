package cmd

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/state"
)

// hubDirEnv names the hub state dir; phase 1 has no default (the live
// app-support folder is phase 3's), so every hub verb needs it.
const hubDirEnv = hub.EnvHubDir

// hubCmd is the `watchtower hub …` parent (Go hub spec §10). This file holds
// the parent, the hub dir, and the two ways a verb writes the sidecar: under
// the hub lock when no hub runs, or over the running hub's control socket
// (hub_link.go). The recording verbs and the Desktop heartbeat are in
// hub_recording.go.
var hubCmd = &cobra.Command{
	Use:   "hub",
	Short: "The phone hub (Go hub POC)",
}

func init() { rootCmd.AddCommand(hubCmd) }

// hubLockWait is how long a CLI write waits for the hub lock (another CLI
// holds it for milliseconds) or, while a hub holds it, for its socket.
var hubLockWait = 3 * time.Second

// hubOpenState opens the sidecar for a direct write (a test seam: a write
// that goes through the running hub never calls it).
var hubOpenState = state.Open

// hubDir is WATCHTOWER_HUB_DIR, required by every hub verb in phase 1.
func hubDir() (string, error) {
	dir := os.Getenv(hubDirEnv)
	if dir == "" {
		return "", fmt.Errorf("%s is not set: the hub verbs need a hub state dir in this phase", hubDirEnv)
	}
	return dir, nil
}

// withHubState opens the sidecar under the hub lock for one write and
// releases both. The control socket carries no recording or heartbeat op, so
// while a hub holds the lock these verbs say so instead of writing beside it.
func withHubState(fn func(dir string, st *state.Store) error) error {
	dir, err := hubDir()
	if err != nil {
		return err
	}
	var lock *state.Lock
	deadline := time.Now().Add(hubLockWait)
	for {
		lock, err = state.AcquireLock(dir)
		if !errors.Is(err, state.ErrLocked) || time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if errors.Is(err, state.ErrLocked) {
		return errors.New("a hub holds this state dir and its control socket does not carry this verb")
	}
	if err != nil {
		return err
	}
	defer func() { _ = lock.Release() }()
	st, err := hubOpenState(dir)
	if err != nil {
		return err
	}
	defer func() { _ = st.Close() }()
	return fn(dir, st)
}

// hubWrite runs one owner write so the sidecar never has two writers: with
// the hub lock in hand (no hub runs) direct writes the sidecar; on
// ErrLocked req goes over <dir>/hub.sock to the hub that holds it. Another
// CLI's brief hold is retried until hubLockWait. A refusal (an answer's
// error class, from the hub or from direct) comes back as an error.
func hubWrite(req hub.ControlRequest, direct func(dir string, st *state.Store) (hub.ControlAnswer, error)) error {
	dir, err := hubDir()
	if err != nil {
		return err
	}
	deadline := time.Now().Add(hubLockWait)
	for {
		lock, err := state.AcquireLock(dir)
		if err == nil {
			a, err := hubWriteDirect(dir, lock, direct)
			if err != nil {
				return err
			}
			return hubAnswerError(a)
		}
		if !errors.Is(err, state.ErrLocked) {
			return err
		}
		if c, derr := hub.Dial(dir); derr == nil {
			a, err := c.Do(req)
			_ = c.Close()
			if err != nil {
				return fmt.Errorf("the hub did not answer: %w", err)
			}
			return hubAnswerError(a)
		}
		if time.Now().After(deadline) {
			return errors.New("the hub state dir is locked and no hub answers on its control socket")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func hubWriteDirect(dir string, lock *state.Lock, direct func(string, *state.Store) (hub.ControlAnswer, error)) (hub.ControlAnswer, error) {
	defer func() { _ = lock.Release() }()
	st, err := hubOpenState(dir)
	if err != nil {
		return hub.ControlAnswer{}, err
	}
	defer func() { _ = st.Close() }()
	return direct(dir, st)
}

// hubAnswerError turns a refused answer into the CLI's error (classes only).
func hubAnswerError(a hub.ControlAnswer) error {
	switch a.Error {
	case "":
		return nil
	case hub.ErrClassNoDevice:
		return errors.New("no such phone")
	case hub.ErrClassUnknownGrant:
		return errors.New("unknown grant: use typing, permissions or start_sessions")
	case hub.ErrClassPolicyOff:
		return errors.New("the MobileSync policy is off: the hub cannot be turned on")
	case hub.ErrClassHubOff:
		// The lock holder runs but its hub is off (disabled, policy, starting).
		return errors.New("the hub is off: turn it on (hub enable) to change a phone")
	case hub.ErrClassBadRequest:
		return errors.New("the hub refused the request as malformed")
	}
	return fmt.Errorf("the hub refused the request (%s)", a.Error)
}

// hubTestWorkspaceOK is hub.FromEnv's workspace check, which the daemon's
// hub passes before it writes anything: false means a hub started now would
// be refused not_test_workspace, a reason no status file ever carries.
func hubTestWorkspaceOK() bool {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		cfg = nil
	}
	_, _, err = hub.FromEnv(cfg, nil)
	return !errors.Is(err, hub.ErrNotTestWorkspace)
}
