package cmd

import (
	"errors"
	"io/fs"

	"github.com/spf13/cobra"

	"watchtower/internal/hub"
	"watchtower/internal/hub/state"
)

// The recording switch (protocol §9): an owner verb, refused under an agent
// marker like the other hub writes. On is refused where no Desktop
// transcriber heartbeat ever arrived, so a headless hub never publishes on.
const hubRecordingsVerb = "turn phone recordings on or off"

// hubRecordingsJSON is `hub recordings on|off --json` (pinned keys).
type hubRecordingsJSON struct {
	Recordings string `json:"recordings"`
	Stored     bool   `json:"stored"`
}

func init() {
	rec := &cobra.Command{Use: "recordings on|off", Short: "Turn phone recordings on or off for this hub",
		Args: cobra.ExactArgs(1), RunE: runHubRecordings}
	rec.Flags().Bool("json", false, "print JSON")
	hubCmd.AddCommand(rec)
}

func runHubRecordings(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(hubRecordingsVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	var on bool
	switch args[0] {
	case state.RecordingsOn:
		on = true
	case state.RecordingsOff:
	default:
		return errors.New("usage: watchtower hub recordings on or off")
	}
	a, err := hubWrite(hub.ControlRequest{Op: hub.OpRecordings, On: on}, func(_ string, st *state.Store) (hub.ControlAnswer, error) {
		if err := st.SetRecordings(on); errors.Is(err, state.ErrNoTranscriber) {
			return hub.ControlAnswer{Error: hub.ErrClassNoTranscriber}, nil
		} else if err != nil {
			return hub.ControlAnswer{}, err
		}
		return hub.ControlAnswer{OK: true, Recordings: args[0]}, nil
	})
	if err != nil {
		return err
	}
	return hubPrint(cmd, asJSON, hubRecordingsJSON{Recordings: a.Recordings, Stored: true}, "recordings "+a.Recordings)
}

// hubRecordingsValue is the switch as `hub status` shows it: "on" | "off";
// a dir with no sidecar yet reads off (no transcriber ever seen).
func hubRecordingsValue(dir string) (string, error) {
	st, err := state.OpenReadOnly(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return state.RecordingsOff, nil
	}
	if err != nil {
		return "", err
	}
	defer func() { _ = st.Close() }()
	on, _, err := st.Recordings()
	if err != nil {
		return "", err
	}
	if on {
		return state.RecordingsOn, nil
	}
	return state.RecordingsOff, nil
}
