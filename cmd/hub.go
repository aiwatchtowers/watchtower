package cmd

import (
	"errors"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/state"
)

// hubDirEnv names the test-mode hub state dir; unset, the verbs work in the
// live hub's dir on a headless host (hub.Dir).
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

// hubProbe is this host's probe (a test seam).
var hubProbe = hostkind.System

// errHubDesktopHost is every verb's refusal but status' on a Mac whose
// mobile link the Watchtower app runs (hub.ErrDesktopHost).
var errHubDesktopHost = errors.New("Mobile on this Mac is run by the Watchtower app.") //nolint:staticcheck // ST1005: the owner's sentence

// hubDir is the dir every hub verb works in: WATCHTOWER_HUB_DIR (test mode),
// else the live hub's dir on a headless host; refused on a desktop host.
func hubDir() (string, error) {
	dir, _, err := hub.Dir(hubProbe())
	if errors.Is(err, hub.ErrDesktopHost) {
		return "", errHubDesktopHost
	}
	return dir, err
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
	case hub.ErrClassNoTranscriber:
		return state.ErrNoTranscriber
	case hub.ErrClassBadRequest:
		return errors.New("the hub refused the request as malformed")
	}
	return fmt.Errorf("the hub refused the request (%s)", a.Error)
}

// hubOffReason is the reason the daemon's hub in mode would stay off before
// it writes any status (hub.OffReason: not_test_workspace, disabled,
// policy_off, no_relay_origin), a reason no status file carries.
func hubOffReason(mode hub.Mode) string {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		cfg = nil
	}
	return hub.OffReason(cfg, mode)
}
