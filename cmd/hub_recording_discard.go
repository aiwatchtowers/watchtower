package cmd

import (
	"errors"

	"github.com/spf13/cobra"

	"watchtower/internal/hub"
	"watchtower/internal/hub/state"
)

// hubDiscardVerb is the owner's Discard of a failed phone recording
// (Settings → Mobile, plan 3 Task 23): it deletes the only copy of the
// audio, so an agent never runs it.
const hubDiscardVerb = "discard a phone recording"

// hubDiscardJSON is `hub recording discard --json` (pinned keys).
type hubDiscardJSON struct {
	UploadID  string `json:"upload_id"`
	Discarded bool   `json:"discarded"`
}

func newHubRecordingDiscardCmd() *cobra.Command {
	c := &cobra.Command{Use: "discard", Short: "Delete a failed phone recording's kept audio and its job",
		Args: cobra.NoArgs, RunE: runHubRecordingDiscard}
	c.Flags().String("upload", "", "upload id")
	c.Flags().Bool("json", false, "print JSON")
	return c
}

// runHubRecordingDiscard discards a failed job through the running hub (it
// republishes the phone's recording_job slice) or, with none, under the lock.
func runHubRecordingDiscard(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubDiscardVerb); err != nil {
		return err
	}
	upload, _ := cmd.Flags().GetString("upload")
	asJSON, _ := cmd.Flags().GetBool("json")
	if upload == "" {
		return errors.New("usage: watchtower hub recording discard --upload <id>")
	}
	_, err := hubWrite(hub.ControlRequest{Op: hub.OpRecordingDiscard, Upload: upload},
		func(dir string, st *state.Store) (hub.ControlAnswer, error) {
			recordings, err := hubRecordingsDir(dir) // a desktop host's are Desktop's recordings folder
			if err != nil {
				return hub.ControlAnswer{}, err
			}
			return hub.RecordingDiscardAnswer(st, recordings, upload), nil
		})
	if err != nil {
		return err
	}
	return hubPrint(cmd, asJSON, hubDiscardJSON{UploadID: upload, Discarded: true}, "discarded "+upload)
}
