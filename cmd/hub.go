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
// the parent, the hub dir, and the one write rule every verb follows: under
// the hub lock when no hub runs, else over the lock holder's control socket.
// The link verbs are in hub_link.go, the recording verbs and the Desktop
// heartbeat in hub_recording.go.
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

// hubWrite runs one write so the sidecar never has two writers: with the
// hub lock in hand (no hub runs) direct writes the sidecar; on ErrLocked req
// goes over <dir>/hub.sock to the process that holds it, which writes. Another
// CLI's brief hold is retried until hubLockWait. A refusal (an answer's
// error class, from the hub or from direct) comes back as an error beside
// the answer.
func hubWrite(req hub.ControlRequest, direct func(dir string, st *state.Store) (hub.ControlAnswer, error)) (hub.ControlAnswer, error) {
	dir, err := hubDir()
	if err != nil {
		return hub.ControlAnswer{}, err
	}
	deadline := time.Now().Add(hubLockWait)
	for {
		lock, err := state.AcquireLock(dir)
		if err == nil {
			a, err := hubWriteDirect(dir, lock, direct)
			if err != nil {
				return a, err
			}
			return a, hubAnswerError(a)
		}
		if !errors.Is(err, state.ErrLocked) {
			return hub.ControlAnswer{}, err
		}
		if c, derr := hub.Dial(dir); derr == nil {
			a, err := c.Do(req)
			_ = c.Close()
			if err != nil {
				return a, fmt.Errorf("the hub did not answer: %w", err)
			}
			return a, hubAnswerError(a)
		}
		if time.Now().After(deadline) {
			return hub.ControlAnswer{}, errors.New("the hub state dir is locked and no hub answers on its control socket")
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
		return errors.New("the hub is not running")
	case hub.ErrClassNoIdentity:
		return errors.New("this hub dir has no hub identity: start the hub once to unlink the phone")
	case hub.ErrClassNoJob:
		return errors.New("no recording job with that upload id")
	case hub.ErrClassJobState:
		return errors.New("the recording job is not in a state that allows this")
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
