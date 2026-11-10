package state

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
	if _, err := s.FinishRecording("u1", nil, "boom", now); !errors.Is(err, ErrJobState) {
		t.Fatalf("finish of a never-claimed job: %v", err)
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

// TestAFailedJobIsClaimedAgainForARetry: the owner's Retry of a failed
// transcription on the Mac claims the job again (the Swift hub's job went
// back to queued the same way), its class, finish and phase cleared; a
// hub_moved job (adoption) and a done one are never claimed.
func TestAFailedJobIsClaimedAgainForARetry(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	for _, id := range []string{"u1", "u2"} {
		if err := s.QueueRecording(id, "aabb", now); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ClaimRecording(id, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.FinishRecording("u1", nil, ClassTranscriptionFailed, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	job, err := s.ClaimRecording("u1", now.Add(time.Hour))
	if err != nil || job.Status != RecordingClaimed || job.ErrorClass != "" || !job.FinishedAt.IsZero() ||
		job.ClaimedAt.Unix() != now.Add(time.Hour).Unix() {
		t.Fatalf("claim of a failed job: %+v %v", job, err)
	}
	tid := int64(9)
	if job, err := s.FinishRecording("u1", &tid, "", now.Add(2*time.Hour)); err != nil || job.Status != RecordingDone {
		t.Fatalf("the retry's finish: %+v %v", job, err)
	}
	if _, err := s.FinishRecording("u2", nil, ClassHubMoved, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimRecording("u2", now); !errors.Is(err, ErrJobState) {
		t.Fatalf("claim of a hub_moved job: %v", err)
	}
	// A failure Desktop did not report (an adopted Swift one: its error text's class) stays terminal.
	if err := s.QueueRecording("u3", "aabb", now); err != nil {
		t.Fatal(err)
	}
	_, _ = s.ClaimRecording("u3", now)
	if _, err := s.FinishRecording("u3", nil, "Disk full", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimRecording("u3", now); !errors.Is(err, ErrJobState) {
		t.Fatalf("claim of a failure Desktop did not report: %v", err)
	}
	// Every class Desktop reports claims again.
	for class := range DesktopFailureClasses {
		id := "d-" + class
		_ = s.QueueRecording(id, "aabb", now)
		_, _ = s.ClaimRecording(id, now)
		_, _ = s.FinishRecording(id, nil, class, now)
		if _, err := s.ClaimRecording(id, now); err != nil {
			t.Errorf("%s: %v", class, err)
		}
	}
}

// TestRecordingEventIDShape: only an id-shaped event id is stored (a
// calendar id's charset, at most 256 bytes); text is dropped.
func TestRecordingEventIDShape(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	cases := map[string]string{
		"abc123_20261102T100000Z":  "abc123_20261102T100000Z",
		"acct-1:evt.2@example.com": "acct-1:evt.2@example.com",
		"Acme sync with colleague": "",
		"evt\n1":                   "",
		strings.Repeat("a", 256):   strings.Repeat("a", 256),
		strings.Repeat("a", 257):   "",
	}
	i := 0
	for in, want := range cases {
		i++
		id := fmt.Sprintf("u%d", i)
		if err := s.QueueRecordingFrom(id, "aabb", RecordingOrigin{EventID: in}, now); err != nil {
			t.Fatal(err)
		}
		job, err := s.RecordingJob(id)
		if err != nil || job.EventID != want {
			t.Errorf("%q stored as %q (%v), want %q", in, job.EventID, err, want)
		}
	}
}

// TestPruneRemovesTheAudioDesktopKeptOnAFailure: the hub's copy of a job
// Desktop failed goes with the job at the prune, and not before; a done
// job's file is Desktop's and stays.
func TestPruneRemovesTheAudioDesktopKeptOnAFailure(t *testing.T) {
	s := openTest(t)
	rec := t.TempDir()
	now := time.Unix(1_800_000_000, 0)
	for _, id := range []string{"failed", "done"} {
		_ = s.QueueRecording(id, "aabb", now)
		_, _ = s.ClaimRecording(id, now)
		if err := os.WriteFile(filepath.Join(rec, id+".m4a"), []byte("a"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	_, _ = s.FinishRecording("failed", nil, ClassIngestFailed, now)
	tid := int64(1)
	_, _ = s.FinishRecording("done", &tid, "", now)
	if n, err := s.PruneRecordingJobs(rec, now.Add(-time.Second)); err != nil || n != 0 {
		t.Fatalf("early prune: %d %v", n, err)
	}
	if _, err := os.Stat(filepath.Join(rec, "failed.m4a")); err != nil {
		t.Fatal("the kept audio went before the prune")
	}
	if n, err := s.PruneRecordingJobs(rec, now.Add(time.Second)); err != nil || n != 2 {
		t.Fatalf("prune: %d %v", n, err)
	}
	if _, err := os.Stat(filepath.Join(rec, "failed.m4a")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the failed job's audio stays: %v", err)
	}
	if _, err := os.Stat(filepath.Join(rec, "done.m4a")); err != nil {
		t.Errorf("a done job's file is Desktop's: %v", err)
	}
}

func TestRecordingJobsHoldNoContent(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	if err := s.QueueRecording("u1", "aabb", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ClaimRecording("u1", now); err != nil {
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
	if _, err := s.ClaimRecording("u2", now); err != nil {
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
