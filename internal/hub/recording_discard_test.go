package hub

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	hubslices "watchtower/internal/hub/slices"
)

// TestRecordingDiscardOverTheSocket: recording_discard removes a failed
// job and the audio the hub kept, answers it and republishes the
// recording_job slice; a job that is not failed is refused and kept.
func TestRecordingDiscardOverTheSocket(t *testing.T) {
	r := newViewRig(t)
	st, s := r.s.st, r.s
	s.o.RecordingsDir = t.TempDir()
	now := time.Now()
	for _, id := range []string{"u1", "u2"} {
		if err := st.QueueRecording(id, "AAAAAAAA-0000-4000-8000-000000000001", now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := st.ClaimRecording("u1", now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.FinishRecording("u1", nil, "boom", now); err != nil {
		t.Fatal(err)
	}
	audio := filepath.Join(s.o.RecordingsDir, "u1.m4a")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingDiscard, Upload: "u1"}, nil); !a.OK || a.UploadID != "u1" {
		t.Fatalf("discard = %+v", a)
	}
	if _, err := os.Stat(audio); !os.IsNotExist(err) {
		t.Errorf("the audio is still there: %v", err)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingDiscard, Upload: "u2"}, nil); a.Error != ErrClassJobState {
		t.Errorf("discard of a queued job = %+v", a)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingDiscard, Upload: "u1"}, nil); a.Error != ErrClassNoJob {
		t.Errorf("discard again = %+v", a)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingDiscard}, nil); a.Error != ErrClassBadRequest {
		t.Errorf("no upload = %+v", a)
	}
	if ok, err := st.HasRecording("u2"); err != nil || !ok {
		t.Errorf("the queued job went: %v %v", ok, err)
	}
	if opClass(OpRecordingDiscard) != OpRecordingDiscard {
		t.Errorf("the op is not logged by name")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.kinds) != 1 || !slices.Equal(r.kinds[0], []hubslices.Kind{recordingJobKind}) {
		t.Errorf("publishes %v, want one of recording_job", r.kinds)
	}
}
