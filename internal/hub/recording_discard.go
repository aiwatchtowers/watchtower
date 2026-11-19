package hub

import (
	"errors"

	"watchtower/internal/hub/state"
)

// OpRecordingDiscard is the owner's Discard of a failed phone recording
// (Settings → Mobile, plan 3 Task 23): its kept audio and its job go now.
// The CLI refuses it under an agent marker.
const OpRecordingDiscard = "recording_discard"

// recordingDiscard discards r.Upload on the running hub and republishes the
// recording_job slice, so the phone drops the row as at the prune.
func (s *supervisor) recordingDiscard(r ControlRequest) ControlAnswer {
	if r.Upload == "" {
		return ControlAnswer{Error: ErrClassBadRequest}
	}
	a := RecordingDiscardAnswer(s.st, s.o.RecordingsDir, r.Upload)
	if a.OK {
		s.hubMu.RLock()
		if s.hub != nil {
			s.hub.publishSoon(recordingJobKind)
		}
		s.hubMu.RUnlock()
	}
	return a
}

// RecordingDiscardAnswer discards upload on st and answers in the control
// socket's shape (the CLI's lock-free path answers through it too).
func RecordingDiscardAnswer(st *state.Store, recordingsDir, upload string) ControlAnswer {
	switch err := st.DiscardRecording(recordingsDir, upload); {
	case errors.Is(err, state.ErrNoRecordingJob):
		return ControlAnswer{Error: ErrClassNoJob}
	case errors.Is(err, state.ErrJobState):
		return ControlAnswer{Error: ErrClassJobState}
	case err != nil:
		return ControlAnswer{Error: ErrClassFailed}
	}
	return ControlAnswer{OK: true, UploadID: upload}
}
