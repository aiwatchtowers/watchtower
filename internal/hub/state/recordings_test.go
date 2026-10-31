package state

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestDesktopHeartbeatFreshFor90s(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0)
	if fresh, seen, err := s.DesktopHost(t0); err != nil || fresh || seen {
		t.Fatalf("before any beat: fresh=%v seen=%v err=%v", fresh, seen, err)
	}
	if err := s.Heartbeat(t0); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		after time.Duration
		fresh bool
	}{{0, true}, {89 * time.Second, true}, {91 * time.Second, false}, {time.Hour, false}} {
		fresh, seen, err := s.DesktopHost(t0.Add(c.after))
		if err != nil || fresh != c.fresh || !seen {
			t.Fatalf("after %v: fresh=%v seen=%v err=%v, want fresh=%v seen=true", c.after, fresh, seen, err, c.fresh)
		}
	}
}

func TestRecordingJobLifecycle(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	if _, err := s.ClaimRecording("u1", now); !errors.Is(err, ErrNoRecordingJob) {
		t.Fatalf("claim of nothing: %v", err)
	}
	if err := s.QueueRecording("u1", "aabb", now); err != nil {
		t.Fatal(err)
	}
	if err := s.QueueRecording("u1", "ccdd", now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	job, err := s.ClaimRecording("u1", now.Add(time.Minute))
	if err != nil || job.Status != RecordingClaimed || job.DeviceID != "AABB" {
		t.Fatalf("claim: %+v %v", job, err)
	}
	if _, err := s.ClaimRecording("u1", now.Add(2*time.Minute)); err != nil {
		t.Fatalf("claim again: %v", err)
	}
	tid := int64(7)
	job, err = s.FinishRecording("u1", &tid, "", now.Add(time.Hour))
	if err != nil || job.Status != RecordingDone || job.TranscriptID == nil || *job.TranscriptID != 7 {
		t.Fatalf("finish: %+v %v", job, err)
	}
	if _, err := s.FinishRecording("u1", &tid, "", now); err != nil {
		t.Fatalf("same finish again: %v", err)
	}
	if _, err := s.FinishRecording("u1", nil, "boom", now); !errors.Is(err, ErrJobState) {
		t.Fatalf("different finish: %v", err)
	}
	if _, err := s.ClaimRecording("u1", now); !errors.Is(err, ErrJobState) {
		t.Fatalf("claim of a done job: %v", err)
	}
}

func TestRecordingJobsHoldNoContent(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	if err := s.QueueRecording("u1", "aabb", now); err != nil {
		t.Fatal(err)
	}
	text := "Could not open /Users/someone/Standup with Acme.m4a"
	job, err := s.FinishRecording("u1", nil, text, now)
	if err != nil || job.Status != RecordingFailed || job.ErrorClass != "other" {
		t.Fatalf("text error: %+v %v", job, err)
	}
	var stored string
	if err := s.db.QueryRow(`SELECT error_class FROM recording_jobs`).Scan(&stored); err != nil || strings.Contains(stored, " ") || stored != "other" {
		t.Fatalf("stored %q %v", stored, err)
	}
	if err := s.QueueRecording("u2", "aabb", now); err != nil {
		t.Fatal(err)
	}
	if job, _ := s.FinishRecording("u2", nil, "decode_failed", now); job.ErrorClass != "decode_failed" {
		t.Fatalf("a class is kept: %+v", job)
	}
}

func TestHasRecordingSeesAdoptedSwiftRows(t *testing.T) {
	s := openTest(t)
	if ok, _ := s.HasRecording("x"); ok {
		t.Fatal("unexpected")
	}
	if _, err := s.db.Exec(`INSERT INTO phone_recordings (upload_id, audio_path, status, updated_at) VALUES ('x', 'p', 'done', 1)`); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.HasRecording("x"); err != nil || !ok {
		t.Fatalf("adopted row: %v %v", ok, err)
	}
}
