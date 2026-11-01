package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/state"
)

// `hub adopt` is the Watchtower app's verb (go hub spec §12, phase 3 Task
// 13): the one-time, resumable import of the Swift hub's MobileHub/ into the
// Go hub's dir, refused under an agent marker. The keys are Task 16's
// separate --keys-stdin call.
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
	if status == settingsIn {
		return errors.New("usage: watchtower hub adopt --status or --settings-stdin")
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

// hubAdoptDirs is the Go hub dir an adoption fills and its recordings dir:
// WATCHTOWER_HUB_DIR and its recordings/ in test mode, else the live dir
// (hub.DefaultDir) and the Mac's <app support>/recordings — the folder
// Desktop's transcriber uses.
func hubAdoptDirs() (dir, recordings string, err error) {
	if d := os.Getenv(hubDirEnv); d != "" {
		return d, filepath.Join(d, "recordings"), nil
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
// recording keeps its audio (or there is no sidecar).
func hubKeptRecordings(cmd *cobra.Command, dir, recordings string) (*adopt.KeptRecordings, error) {
	st, err := state.OpenReadOnly(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = st.Close() }()
	k, err := adopt.Kept(cmd.Context(), st, recordings)
	if err != nil || k.Count == 0 {
		return nil, err
	}
	return &k, nil
}
