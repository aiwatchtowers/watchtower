package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/state"
)

// The recording verbs and the Desktop heartbeat are Desktop's alone (spec
// §8 p. 4a): Desktop never runs under an agent marker, so an agent that could
// call them could fake a desktop host (clipboard fallback, recordings
// written) or mark a job done. Refused under every marker.
const (
	hubHeartbeatVerb = "report a Desktop heartbeat"
	hubClaimVerb     = "claim a recording job"
	hubFinishVerb    = "finish a recording job"
)

// hubHeartbeatJSON is `hub desktop heartbeat --json` (pinned keys).
type hubHeartbeatJSON struct {
	DesktopAt string `json:"desktop_at"`
}

// hubClaimJSON is `hub recording claim --json` (pinned keys).
type hubClaimJSON struct {
	UploadID  string `json:"upload_id"`
	AudioPath string `json:"audio_path"`
	Status    string `json:"status"`
}

// hubFinishJSON is `hub recording finish --json` (pinned keys).
type hubFinishJSON struct {
	UploadID     string `json:"upload_id"`
	Status       string `json:"status"`
	TranscriptID *int64 `json:"transcript_id"`
}

// hubNow is the verbs' clock (a test seam).
var hubNow = time.Now

func init() {
	desktop := &cobra.Command{Use: "desktop", Short: "Desktop's reports to the hub"}
	beat := &cobra.Command{Use: "heartbeat", Short: "Tell the hub Desktop (the transcriber) is running", Args: cobra.NoArgs, RunE: runHubDesktopHeartbeat}
	beat.Flags().Bool("json", false, "print JSON")
	desktop.AddCommand(beat)

	recording := &cobra.Command{Use: "recording", Short: "Phone recording jobs"}
	claim := &cobra.Command{Use: "claim", Short: "Take a queued recording job", Args: cobra.NoArgs, RunE: runHubRecordingClaim}
	claim.Flags().String("upload", "", "upload id")
	claim.Flags().Bool("json", false, "print JSON")
	finish := &cobra.Command{Use: "finish", Short: "End a claimed recording job", Args: cobra.NoArgs, RunE: runHubRecordingFinish}
	finish.Flags().String("upload", "", "upload id")
	finish.Flags().Int64("transcript", 0, "transcript id the job produced")
	finish.Flags().String("error", "", "error class when the job failed (only the class is stored)")
	finish.Flags().Bool("json", false, "print JSON")
	recording.AddCommand(claim, finish)
	hubCmd.AddCommand(desktop, recording)
}

func hubPrint(cmd *cobra.Command, asJSON bool, v any, line string) error {
	if !asJSON {
		_, err := fmt.Fprintln(cmd.OutOrStdout(), line)
		return err
	}
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(cmd.OutOrStdout(), string(b))
	return err
}

func runHubDesktopHeartbeat(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubHeartbeatVerb); err != nil {
		return err
	}
	asJSON, _ := cmd.Flags().GetBool("json")
	now := hubNow()
	return withHubState(func(_ string, st *state.Store) error {
		if err := st.Heartbeat(now); err != nil {
			return err
		}
		at := now.UTC().Format(time.RFC3339)
		return hubPrint(cmd, asJSON, hubHeartbeatJSON{DesktopAt: at}, "desktop heartbeat at "+at)
	})
}

func runHubRecordingClaim(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubClaimVerb); err != nil {
		return err
	}
	upload, _ := cmd.Flags().GetString("upload")
	asJSON, _ := cmd.Flags().GetBool("json")
	if upload == "" {
		return errors.New("usage: watchtower hub recording claim --upload <id>")
	}
	return withHubState(func(dir string, st *state.Store) error {
		job, err := st.ClaimRecording(upload, hubNow())
		if err != nil {
			return recordingJobError(upload, err)
		}
		path := handlers.RecordingAudioPath(handlers.RecordingsDirUnder(dir), job.UploadID)
		return hubPrint(cmd, asJSON, hubClaimJSON{UploadID: job.UploadID, AudioPath: path, Status: job.Status},
			"claimed "+job.UploadID+": "+path)
	})
}

func runHubRecordingFinish(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent(hubFinishVerb); err != nil {
		return err
	}
	upload, _ := cmd.Flags().GetString("upload")
	asJSON, _ := cmd.Flags().GetBool("json")
	errClass, _ := cmd.Flags().GetString("error")
	hasTranscript := cmd.Flags().Changed("transcript")
	switch {
	case upload == "":
		return errors.New("usage: watchtower hub recording finish --upload <id> (--transcript <id> | --error <class>)")
	case hasTranscript == (errClass != ""):
		return errors.New("finish needs exactly one of --transcript and --error")
	}
	var tid *int64
	if hasTranscript {
		v, _ := cmd.Flags().GetInt64("transcript")
		if v <= 0 {
			return errors.New("--transcript must be a transcript id")
		}
		tid = &v
	}
	return withHubState(func(_ string, st *state.Store) error {
		job, err := st.FinishRecording(upload, tid, errClass, hubNow())
		if err != nil {
			return recordingJobError(upload, err)
		}
		line := "finished " + job.UploadID + ": " + job.Status
		if job.TranscriptID != nil {
			line += " (transcript " + strconv.FormatInt(*job.TranscriptID, 10) + ")"
		}
		return hubPrint(cmd, asJSON, hubFinishJSON{UploadID: job.UploadID, Status: job.Status, TranscriptID: job.TranscriptID}, line)
	})
}

func recordingJobError(upload string, err error) error {
	switch {
	case errors.Is(err, state.ErrNoRecordingJob):
		return fmt.Errorf("no recording job %q", upload)
	case errors.Is(err, state.ErrJobState):
		return fmt.Errorf("recording job %q is not in a state that allows this", upload)
	}
	return err
}
