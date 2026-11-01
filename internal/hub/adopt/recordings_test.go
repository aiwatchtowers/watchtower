package adopt

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
)

func TestPhoneRecordingsMapToRecordingJobs(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	at := fromReal(f.updated)
	jobs := map[string]state.RecordingJob{}
	list, err := f.store(t).RecordingJobs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, j := range list {
		jobs[j.UploadID] = j
	}
	if len(jobs) != len(swiftStatuses) {
		t.Fatalf("jobs = %+v", list)
	}
	for _, tc := range []struct {
		swift, status, class string
		tid                  int64
	}{
		{"received", "failed", "hub_moved", 0},
		{"queued", "failed", "hub_moved", 0},
		{"transcribing", "failed", "hub_moved", 0},
		{"diarizing", "failed", "hub_moved", 0},
		{"summarizing", "failed", "hub_moved", 0},
		{"done", "done", "", 7},
		{"failed", "failed", "other", 0},
	} {
		j := jobs["rec-"+tc.swift]
		if j.Status != tc.status || j.ErrorClass != tc.class || j.DeviceID != "" {
			t.Errorf("%s → %+v", tc.swift, j)
		}
		if (tc.tid == 0) != (j.TranscriptID == nil) || (j.TranscriptID != nil && *j.TranscriptID != tc.tid) {
			t.Errorf("%s transcript = %v", tc.swift, j.TranscriptID)
		}
		if !j.CreatedAt.Equal(at) || !j.FinishedAt.Equal(at) {
			t.Errorf("%s times = %v %v, want %v", tc.swift, j.CreatedAt, j.FinishedAt, at)
		}
	}
	if _, ok := jobs["bad/id"]; ok {
		t.Error("a row whose id is no file name was imported")
	}
}

func TestRecordingMidTranscriptionAtAdoptionFailsOnceWithHubMoved(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	inProgress := swiftStatuses[:5]
	for _, s := range inProgress {
		dst := filepath.Join(f.rec, "rec-"+s+".m4a")
		b, err := os.ReadFile(dst)
		if err != nil || string(b) != "audio of "+s {
			t.Errorf("%s audio at %s = %q %v", s, dst, b, err)
		}
		if fi, err := os.Stat(dst); err == nil && fi.Mode().Perm() != 0o600 {
			t.Errorf("%s audio mode = %v", s, fi.Mode().Perm())
		}
		if exists(filepath.Join(f.pending, "acme standup "+s+".m4a")) {
			t.Errorf("%s: the Swift name is still there", s)
		}
	}
	for _, s := range []string{"done", "failed"} {
		if !exists(filepath.Join(f.pending, "acme standup "+s+".m4a")) || exists(filepath.Join(f.rec, "rec-"+s+".m4a")) {
			t.Errorf("%s: a finished recording's audio moved", s)
		}
	}
	snap := f.snapshot(t)
	if _, err := f.run(t); !errors.Is(err, ErrAlreadyAdopted) {
		t.Fatalf("second run = %v", err)
	}
	// Later passes: the slice publishes the fixed text; nothing changes.
	st := f.store(t)
	src, err := sources.RecordingJob(st, func() time.Time { return fromReal(f.updated).Add(time.Hour) })
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		items, err := src.Items(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, it := range items {
			if strings.Contains(string(it.Payload), `"status":"failed"`) && bytes.Contains(it.Payload, []byte(sources.HubMovedText)) {
				n++
			}
		}
		if n != len(inProgress) {
			t.Fatalf("hub_moved items = %d", n)
		}
	}
	_ = st.Close()
	if after := f.snapshot(t); after != snap {
		t.Fatalf("a later pass changed the state:\n%s\nvs\n%s", after, snap)
	}
	// The recording_upload echo in the ledger is untouched.
	if v := scalar[string](t, f.goDB(t), `SELECT hex(echo) || outcome FROM relay_processed WHERE record_name = 'a-upload-1'`); v != "E0E1E2received" {
		t.Fatalf("echo = %q", v)
	}
}

func TestHubMovedAudioIsPrunedWithItsJobAfter31Days(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	st := f.store(t)
	finished := fromReal(f.updated)
	day := 24 * time.Hour
	if n, err := st.PruneRecordingJobs(f.rec, finished.Add(30*day).Add(-state.RecordingJobKeptFor)); err != nil || n != 0 {
		t.Fatalf("prune at 30 d = %d %v", n, err)
	}
	if !exists(filepath.Join(f.rec, "rec-queued.m4a")) {
		t.Fatal("the audio went before 31 days")
	}
	// The done job has no file in the recordings dir: no error.
	n, err := st.PruneRecordingJobs(f.rec, finished.Add(31*day).Add(-state.RecordingJobKeptFor))
	if err != nil || n != len(swiftStatuses) {
		t.Fatalf("prune at 31 d = %d %v", n, err)
	}
	for _, s := range swiftStatuses {
		if exists(filepath.Join(f.rec, "rec-"+s+".m4a")) {
			t.Errorf("%s audio kept", s)
		}
	}
	if jobs, _ := st.RecordingJobs(context.Background()); len(jobs) != 0 {
		t.Fatalf("jobs left = %+v", jobs)
	}
}

func TestAdoptedJobsHoldNoText(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	db := f.goDB(t)
	if n := scalar[int](t, db, `SELECT count(*) FROM phone_recordings WHERE audio_path != '' OR error IS NOT NULL`); n != 0 {
		t.Fatalf("%d phone_recordings rows keep text", n)
	}
	_ = db.Close()
	needles := []string{"acme standup", errCanary, f.pending}
	ents, _ := os.ReadDir(f.hub)
	for _, e := range ents {
		if !strings.HasPrefix(e.Name(), state.FileName) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(f.hub, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, n := range needles {
			if bytes.Contains(b, []byte(n)) {
				t.Errorf("%s holds %q", e.Name(), n)
			}
		}
	}
}

func TestAdoptStatusListsPendingRecordingsBeforeTheStep(t *testing.T) {
	f := newFixture(t)
	rep, err := Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	want := []PendingRecording{
		{"rec-diarizing", "acme standup diarizing.m4a"},
		{"rec-queued", "acme standup queued.m4a"},
		{"rec-received", "acme standup received.m4a"},
		{"rec-summarizing", "acme standup summarizing.m4a"},
		{"rec-transcribing", "acme standup transcribing.m4a"},
	}
	// The invalid-id row is in progress too: listed, its empty path gives no name.
	want = append([]PendingRecording{{"bad/id", ""}}, want...)
	if !equalPending(rep.PendingRecordings, want) || rep.SwiftState != "present" || rep.HubID != fixtureHubID || rep.Identity != "none" || rep.Step != "" {
		t.Fatalf("status before = %+v", rep)
	}
	// Killed right before the recordings step: read from the Go file now.
	killAt(t, "migrate")
	if _, err := f.run(t); err == nil {
		t.Fatal("no kill")
	}
	if rep, _ = Status(f.mobile, f.hub); !equalPending(rep.PendingRecordings, want) || rep.Step != StepRecordings {
		t.Fatalf("status before the step = %+v", rep)
	}
	f.mustRun(t)
	rep, err = Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.PendingRecordings) != 0 || rep.PendingRecordings == nil || rep.SwiftState != "absent" || rep.Step != StepDone ||
		rep.Imported != (Counts{Devices: 2, Jobs: 7, Skipped: 1}) {
		t.Fatalf("status after = %+v", rep)
	}
}

func equalPending(a, b []PendingRecording) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestKeptRecordings(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	st := f.store(t)
	k, err := Kept(context.Background(), st, f.rec)
	if err != nil {
		t.Fatal(err)
	}
	if k.Count != 5 || !k.RemoveAt.Equal(fromReal(f.updated).Add(31*24*time.Hour)) || k.Dir != f.rec {
		t.Fatalf("kept = %+v", k)
	}
	_ = os.Remove(filepath.Join(f.rec, "rec-queued.m4a"))
	if k, _ := Kept(context.Background(), st, f.rec); k.Count != 4 {
		t.Fatalf("kept after one file went = %+v", k)
	}
}
