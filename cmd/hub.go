package cmd

import (
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/actions/handlers"
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

// hostProbe is this host's probe for the hub verbs and the daemon's hub (a
// test seam).
var hostProbe = hostkind.System

// errHubDesktopHost is every write's refusal on a Mac whose mobile link the
// Watchtower app's Swift hub still runs: its state waits for the adoption,
// and a sidecar written first would make the adoption refuse it (never two
// hubs, spec §12.1).
var errHubDesktopHost = errors.New("Mobile on this Mac is run by the Watchtower app.") //nolint:staticcheck // ST1005: the owner's sentence

// hubDir is the dir every hub verb works in: WATCHTOWER_HUB_DIR (test mode),
// else the live hub's dir (a headless or a desktop host).
func hubDir() (string, error) {
	dir, _, _, err := hub.Dir(hostProbe())
	return dir, err
}

// hubMobileHubDir is the Swift hub's MobileHub/ (looked at, never opened).
func hubMobileHubDir() (string, error) {
	support, err := config.AppSupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(support, "MobileHub"), nil
}

// hubWriteDir is hubDir for a write: on a desktop host refused while the
// Swift hub's state waits for its adoption.
func hubWriteDir() (string, error) {
	dir, mode, host, err := hub.Dir(hostProbe())
	if err != nil || mode != hub.ModeLive || host != hostkind.Desktop {
		return dir, err
	}
	mobile, err := hubMobileHubDir()
	if err != nil {
		return "", err
	}
	waiting, err := hub.AwaitingAdoption(dir, mobile)
	if err != nil {
		return "", err
	}
	if waiting {
		return "", errHubDesktopHost
	}
	return dir, nil
}

// hubRecordingsDir is where the hub keeps the phones' recordings: the Mac's
// <app support>/recordings (the transcriber's folder) on a desktop host's
// live hub, else <dir>/recordings.
func hubRecordingsDir(dir string) (string, error) {
	_, mode, host, err := hub.Dir(hostProbe())
	if err != nil {
		return "", err
	}
	if mode == hub.ModeLive && host == hostkind.Desktop {
		support, err := config.AppSupportDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(support, "recordings"), nil
	}
	return handlers.RecordingsDirUnder(dir), nil
}

// hubWrite runs one write so the sidecar never has two writers: with the
// hub lock in hand (no hub runs) direct writes the sidecar; on ErrLocked req
// goes over <dir>/hub.sock to the process that holds it, which writes. Another
// CLI's brief hold is retried until hubLockWait. A refusal (an answer's
// error class, from the hub or from direct) comes back as an error beside
// the answer.
func hubWrite(req hub.ControlRequest, direct func(dir string, st *state.Store) (hub.ControlAnswer, error)) (hub.ControlAnswer, error) {
	dir, err := hubWriteDir()
	if err != nil {
		return hub.ControlAnswer{}, err
	}
	return hubWriteAt(dir, req, func(lock *state.Lock) (hub.ControlAnswer, error) {
		return hubWriteDirect(dir, lock, direct)
	})
}

// hubWriteAt is hubWrite in dir with a direct step that gets the held lock
// (and releases it) and opens what it needs itself: `hub adopt
// --confirm-deleted` must not create a sidecar.
func hubWriteAt(dir string, req hub.ControlRequest, direct func(lock *state.Lock) (hub.ControlAnswer, error)) (hub.ControlAnswer, error) {
	deadline := time.Now().Add(hubLockWait)
	for {
		lock, err := state.AcquireLock(dir)
		if err == nil {
			a, err := direct(lock)
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
// policy_off, no_relay_origin; on a desktop host hub.DesktopOffReason:
// awaiting_adoption, adoption_failed, disabled, policy_off), a reason no
// status file carries.
func hubOffReason(dir string, mode hub.Mode, host hostkind.Kind) string {
	if mode == hub.ModeLive && host == hostkind.Desktop {
		mobile, err := hubMobileHubDir()
		if err != nil {
			return ""
		}
		return hub.DesktopOffReason(dir, mobile)
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		cfg = nil
	}
	return hub.OffReason(cfg, mode)
}
