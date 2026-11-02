package state

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// failedJob queues, claims and fails uploadID with class.
func failedJob(t *testing.T, s *Store, uploadID, class string) {
	t.Helper()
	now := time.Unix(1_800_000_000, 0)
	if err := s.QueueRecording(uploadID, "aabb", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimRecording(uploadID, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.FinishRecording(uploadID, nil, class, now); err != nil {
		t.Fatal(err)
	}
}

// The owner's Discard of a failed phone recording (plan 3 Task 23): the
// hub's kept audio and the row go; a second Discard finds nothing.
func TestDiscardRecordingRemovesAFailedJobAndItsAudio(t *testing.T) {
	s := openTest(t)
	dir := t.TempDir()
	failedJob(t, s, "u1", "not_audio")
	audio := filepath.Join(dir, "u1.m4a")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.DiscardRecording(dir, "u1"); err != nil {
		t.Fatalf("discard: %v", err)
	}
	if _, err := os.Stat(audio); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the audio is still there: %v", err)
	}
	if ok, err := s.HasRecording("u1"); err != nil || ok {
		t.Fatalf("the row is still there: %v %v", ok, err)
	}
	if err := s.DiscardRecording(dir, "u1"); !errors.Is(err, ErrNoRecordingJob) {
		t.Fatalf("a second discard: %v", err)
	}
}

// A job that is not failed (queued, claimed, done) is refused and kept,
// its audio with it.
func TestDiscardRecordingRefusesAJobThatIsNotFailed(t *testing.T) {
	s := openTest(t)
	dir := t.TempDir()
	if err := s.QueueRecording("u2", "aabb", time.Unix(1_800_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	audio := filepath.Join(dir, "u2.m4a")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.DiscardRecording(dir, "u2"); !errors.Is(err, ErrJobState) {
		t.Fatalf("discard of a queued job: %v", err)
	}
	if _, err := os.Stat(audio); err != nil {
		t.Fatalf("a refused discard removed the audio: %v", err)
	}
	if ok, err := s.HasRecording("u2"); err != nil || !ok {
		t.Fatalf("a refused discard removed the row: %v %v", ok, err)
	}
}

// Audio already gone (the prune, the owner in Finder) is no error.
func TestDiscardRecordingWithoutItsAudioStillRemovesTheRow(t *testing.T) {
	s := openTest(t)
	failedJob(t, s, "u3", ClassHubMoved)
	if err := s.DiscardRecording(t.TempDir(), "u3"); err != nil {
		t.Fatalf("discard with no audio left: %v", err)
	}
	if ok, err := s.HasRecording("u3"); err != nil || ok {
		t.Fatalf("the row is still there: %v %v", ok, err)
	}
}

// A claim that comes first (a Retry re-claims a job Desktop failed) wins:
// the Discard finds a claimed job, refuses, and leaves the row and its
// audio for the transcription under way.
func TestDiscardRecordingLosesToAClaim(t *testing.T) {
	s := openTest(t)
	dir := t.TempDir()
	failedJob(t, s, "u4", ClassNotAudio)
	audio := filepath.Join(dir, "u4.m4a")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimRecording("u4", time.Unix(1_800_000_100, 0)); err != nil {
		t.Fatalf("re-claiming a Desktop failure: %v", err)
	}
	if err := s.DiscardRecording(dir, "u4"); !errors.Is(err, ErrJobState) {
		t.Fatalf("discard after a claim: %v", err)
	}
	if _, err := os.Stat(audio); err != nil {
		t.Fatalf("the claimed job's audio went: %v", err)
	}
	if ok, err := s.HasRecording("u4"); err != nil || !ok {
		t.Fatalf("the claimed job went: %v %v", ok, err)
	}
}
