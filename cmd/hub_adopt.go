package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
)

// `hub adopt` is the Watchtower app's verb (go hub spec §12, phase 3 Task
// 13): the one-time, resumable import of the Swift hub's MobileHub/ into the
// Go hub's dir, refused under an agent marker. The keys are a separate
// call (Task 16): --keys-stdin, then --confirm-deleted once the app deleted
// its own items.
const hubAdoptVerb = "adopt the Watchtower app's phone hub"

// hubAdoptSettingsMax caps the settings Desktop sends on stdin.
const hubAdoptSettingsMax = 1 << 20

func init() {
	c := &cobra.Command{
		Use:   "adopt",
		Short: "Take over the Watchtower app's phone hub (run by the app)",
		Args:  cobra.NoArgs,
		RunE:  runHubAdopt,
	}
	c.Flags().Bool("json", false, "print JSON")
	c.Flags().Bool("settings-stdin", false, "adopt, with the app's settings as JSON on stdin")
	c.Flags().Bool("status", false, "print where the adoption stands")
	c.Flags().Bool("keys-stdin", false, "hand the app's hub keys over, as JSON on stdin")
	c.Flags().Bool("confirm-deleted", false, "record that the app deleted its own hub keys")
	c.Flags().String("mobile-hub", "", "the Swift hub's dir (tests only)")
	_ = c.Flags().MarkHidden("mobile-hub")
	hubCmd.AddCommand(c)
}

func runHubAdopt(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubAdoptVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	status, _ := cmd.Flags().GetBool("status")
	settingsIn, _ := cmd.Flags().GetBool("settings-stdin")
	keysIn, _ := cmd.Flags().GetBool("keys-stdin")
	confirm, _ := cmd.Flags().GetBool("confirm-deleted")
	// One call, one job: the keys never share stdin with the settings.
	n := 0
	for _, b := range []bool{status, settingsIn, keysIn, confirm} {
		if b {
			n++
		}
	}
	if n != 1 {
		return errors.New("usage: watchtower hub adopt --status or --settings-stdin, or --keys-stdin or --confirm-deleted (one per call)")
	}
	if keysIn || confirm {
		return runHubAdoptKeys(cmd, asJSON, keysIn)
	}
	mobile, _ := cmd.Flags().GetString("mobile-hub")
	if mobile == "" {
		support, err := config.AppSupportDir()
		if err != nil {
			return err
		}
		mobile = filepath.Join(support, "MobileHub")
	}
	dir, rec, err := hubAdoptDirs()
	if err != nil {
		return err
	}
	if status {
		rep, err := adopt.Status(mobile, dir)
		if err != nil {
			return err
		}
		line := fmt.Sprintf("adoption: step %q, Swift hub state %s, identity %s, %d recording(s) pending", rep.Step, rep.SwiftState, rep.Identity, len(rep.PendingRecordings))
		return hubPrint(cmd, asJSON, rep, line)
	}
	var s adopt.Settings
	if err := json.NewDecoder(io.LimitReader(cmd.InOrStdin(), hubAdoptSettingsMax)).Decode(&s); err != nil {
		return fmt.Errorf("reading the settings on stdin: %w", err)
	}
	res, runErr := adopt.Run(cmd.Context(), mobile, dir, rec, s, nil)
	line := fmt.Sprintf("adoption: %s, %d phone(s), %d recording job(s), %d skipped", res.Step, res.Imported.Devices, res.Imported.Jobs, res.Imported.Skipped)
	if runErr != nil {
		line = fmt.Sprintf("adoption stopped at %s (%s)", res.Step, res.Error)
	}
	if err := hubPrint(cmd, asJSON, res, line); err != nil {
		return err
	}
	return runErr
}

// hubIdentityAnswer is the key hand-over's JSON: adopted|confirmed, or the
// error class.
type hubIdentityAnswer struct {
	Identity string `json:"identity"`
}

// runHubAdoptKeys is `hub adopt --keys-stdin` (the Swift hub's keys on
// stdin, never a file, argv or the control socket; spec §12.2) and
// `--confirm-deleted`. The identity store is the desktop host's recorded
// one; in test mode (WATCHTOWER_HUB_DIR) always the file store, never the
// login Keychain.
func runHubAdoptKeys(cmd *cobra.Command, asJSON, keysIn bool) error {
	dir, _, err := hubAdoptDirs()
	if err != nil {
		return err
	}
	testMode := os.Getenv(hubDirEnv) != ""
	var ans string
	var opErr error
	if keysIn {
		// Under the hub lock inside; an identity already adopted answers
		// read-only, so it works beside a running hub.
		ans, opErr = adopt.HandOverDesktop(cmd.Context(), dir, cmd.InOrStdin(), identity.KeychainUsable && !testMode, testMode)
	} else {
		// One writer: direct under the hub lock, else the running hub.
		_, opErr = hubWriteAt(dir, hub.ControlRequest{Op: hub.OpConfirmDeleted}, func(lock *state.Lock) (hub.ControlAnswer, error) {
			defer func() { _ = lock.Release() }()
			if err := adopt.ConfirmDeleted(dir); err != nil {
				return hub.ControlAnswer{Error: adopt.KeysClass(err)}, nil
			}
			return hub.ControlAnswer{OK: true}, nil
		})
		ans = adopt.IdentityConfirmed
		if opErr != nil {
			ans = confirmClass(opErr)
		}
	}
	line := "identity: " + ans
	if opErr != nil {
		line = fmt.Sprintf("key hand-over refused (%s)", ans)
	}
	if err := hubPrint(cmd, asJSON, hubIdentityAnswer{Identity: ans}, line); err != nil {
		return err
	}
	return opErr
}

// confirmClass is the class a refused --confirm-deleted answers: the hub's
// or ConfirmDeleted's class (hubAnswerError's "(class)" text), else failed.
func confirmClass(err error) string {
	for _, c := range []string{adopt.ClassNotAdopted, adopt.ClassNoSidecar, adopt.ClassAdoptionUnfinished, adopt.ClassLocked} {
		if strings.Contains(err.Error(), "("+c+")") {
			return c
		}
	}
	return adopt.ClassFailed
}

// hubAdoptDirs is the Go hub dir an adoption fills and its recordings dir:
// WATCHTOWER_HUB_DIR and its recordings/ in test mode, else the live dir
// (hub.DefaultDir) and the Mac's <app support>/recordings — the folder
// Desktop's transcriber uses.
func hubAdoptDirs() (dir, recordings string, err error) {
	if d := os.Getenv(hubDirEnv); d != "" {
		return d, handlers.RecordingsDirUnder(d), nil
	}
	if dir, err = hub.DefaultDir(); err != nil {
		return "", "", err
	}
	support, err := config.AppSupportDir()
	if err != nil {
		return "", "", err
	}
	return dir, filepath.Join(support, "recordings"), nil
}

// hubKeptRecordings is `hub status`'s kept_recordings: nil when no hub_moved
// recording keeps its audio, when there is no sidecar, or when it cannot be
// read (mid-adoption): the status itself never fails on it.
func hubKeptRecordings(cmd *cobra.Command, dir, recordings string) *adopt.KeptRecordings {
	st, err := state.OpenReadOnly(dir)
	if err != nil {
		return nil
	}
	defer func() { _ = st.Close() }()
	k, err := adopt.Kept(cmd.Context(), st, recordings)
	if err != nil || k.Count == 0 {
		return nil
	}
	return &k
}
