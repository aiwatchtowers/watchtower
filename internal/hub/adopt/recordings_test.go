package adopt

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
)

func TestPhoneRecordingsMapToRecordingJobs(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	updated := fromReal(f.updated)
	jobs := map[string]state.RecordingJob{}
	list, err := f.store(t).RecordingJobs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, j := range list {
		jobs[j.UploadID] = j
	}
	if len(jobs) != len(swiftStatuses)+1 {
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
		// A hub_moved job finishes at the adoption: the phone sees the
		// text and its 31 days start then.
		finished := updated
		if tc.class == "hub_moved" {
			finished = f.now
		}
		if !j.CreatedAt.Equal(updated) || !j.FinishedAt.Equal(finished) {
			t.Errorf("%s times = %v %v, want %v %v", tc.swift, j.CreatedAt, j.FinishedAt, updated, finished)
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
		if exists(filepath.Join(f.rec, "acme standup "+s+".m4a")) {
			t.Errorf("%s: the Swift name is still there", s)
		}
	}
	for _, s := range []string{"done", "failed"} {
		if !exists(filepath.Join(f.rec, "acme standup "+s+".m4a")) || exists(filepath.Join(f.rec, "rec-"+s+".m4a")) {
			t.Errorf("%s: a finished recording's audio moved", s)
		}
	}
	// The audio outside the transcriber's folder stays, its path kept.
	if !exists(filepath.Join(f.outside, "acme outside.m4a")) || exists(filepath.Join(f.rec, "rec-outside.m4a")) {
		t.Error("the outside audio moved")
	}
	if v := scalar[string](t, f.goDB(t), `SELECT audio_path FROM phone_recordings WHERE upload_id = 'rec-outside'`); v != filepath.Join(f.outside, "acme outside.m4a") {
		t.Errorf("outside row path = %q", v)
	}
	snap := f.snapshot(t)
	if _, err := f.run(t); !errors.Is(err, ErrAlreadyAdopted) {
		t.Fatalf("second run = %v", err)
	}
	// Later passes: the slice publishes the fixed text; nothing changes.
	st := f.store(t)
	src, err := sources.RecordingJob(st, func() time.Time { return f.now.Add(time.Hour) })
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
		if n != len(inProgress)+1 {
			t.Fatalf("hub_moved items = %d", n)
		}
	}
	_ = st.Close()
	if after := f.snapshot(t); after != snap {
		t.Fatalf("a later pass changed the state:\n%s\nvs\n%s", after, snap)
	}
	if v := scalar[string](t, f.goDB(t), `SELECT hex(echo) || outcome FROM relay_processed WHERE record_name = 'a-upload-1'`); v != "E0E1E2received" {
		t.Fatalf("echo = %q", v)
	}
}

// TestAudioMovesAcrossVolumes: a rename refused with EXDEV is a copy, a
// sync and an unlink.
func TestAudioMovesAcrossVolumes(t *testing.T) {
	prev := renameFile
	renameFile = func(from, to string) error {
		if strings.HasSuffix(to, ".m4a") && !strings.Contains(filepath.Base(to), ".adopt-") {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renameFile = prev })
	f := newFixture(t)
	res := f.mustRun(t)
	if res.Imported.AudioLeft != 1 {
		t.Fatalf("counts = %+v", res.Imported)
	}
	b, err := os.ReadFile(filepath.Join(f.rec, "rec-queued.m4a"))
	if err != nil || string(b) != "audio of queued" {
		t.Fatalf("copied audio = %q %v", b, err)
	}
	if exists(filepath.Join(f.rec, "acme standup queued.m4a")) {
		t.Fatal("the source was kept")
	}
}

// TestAudioThatCannotMoveKeepsItsPath: a failed move leaves the audio and
// the row's path, is counted, and is not "kept".
func TestAudioThatCannotMoveKeepsItsPath(t *testing.T) {
	prev := renameFile
	renameFile = func(from, to string) error {
		if strings.HasSuffix(to, "rec-diarizing.m4a") {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EACCES}
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renameFile = prev })
	f := newFixture(t)
	res := f.mustRun(t)
	if res.Imported.AudioLeft != 2 {
		t.Fatalf("counts = %+v", res.Imported)
	}
	src := filepath.Join(f.rec, "acme standup diarizing.m4a")
	if !exists(src) {
		t.Fatal("the audio went")
	}
	if v := scalar[string](t, f.goDB(t), `SELECT audio_path FROM phone_recordings WHERE upload_id = 'rec-diarizing'`); v != src {
		t.Fatalf("path = %q", v)
	}
	k, err := Kept(context.Background(), f.store(t), f.rec)
	if err != nil || k.Count != 4 {
		t.Fatalf("kept = %+v %v", k, err)
	}
}

func TestHubMovedAudioIsPrunedWithItsJobAfter31Days(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	st := f.store(t)
	day := 24 * time.Hour
	// A Go-queued job's audio beside them: Desktop's, never pruned here.
	if err := os.WriteFile(filepath.Join(f.rec, "rec-done.m4a"), []byte("desktop's"), 0o600); err != nil {
		t.Fatal(err)
	}
	// 30 days after the adoption everything stays.
	n, err := st.PruneRecordingJobs(f.rec, f.now.Add(30*day).Add(-state.RecordingJobKeptFor))
	if err != nil || n != 0 {
		t.Fatalf("prune at 30 d = %d %v", n, err)
	}
	if !exists(filepath.Join(f.rec, "rec-queued.m4a")) {
		t.Fatal("the audio went before 31 days")
	}
	// 31 days: every row goes; only the hub_moved jobs' audio with them.
	n, err = st.PruneRecordingJobs(f.rec, f.now.Add(31*day).Add(-state.RecordingJobKeptFor))
	if err != nil || n != len(swiftStatuses)+1 {
		t.Fatalf("prune at 31 d = %d %v", n, err)
	}
	for _, s := range swiftStatuses[:5] {
		if exists(filepath.Join(f.rec, "rec-"+s+".m4a")) {
			t.Errorf("%s audio kept", s)
		}
	}
	for _, name := range []string{"rec-done.m4a", "acme standup done.m4a", "acme standup failed.m4a"} {
		if !exists(filepath.Join(f.rec, name)) {
			t.Errorf("%s removed with a row that is not hub_moved", name)
		}
	}
	if !exists(filepath.Join(f.outside, "acme outside.m4a")) {
		t.Error("the audio left outside was removed")
	}
	if jobs, _ := st.RecordingJobs(context.Background()); len(jobs) != 0 {
		t.Fatalf("jobs left = %+v", jobs)
	}
}

func TestAdoptedJobsHoldNoText(t *testing.T) {
	f := newFixture(t)
	f.mustRun(t)
	db := f.goDB(t)
	if n := scalar[int](t, db, `SELECT count(*) FROM phone_recordings WHERE (audio_path != '' AND upload_id != 'rec-outside') OR error IS NOT NULL`); n != 0 {
		t.Fatalf("%d phone_recordings rows keep text", n)
	}
	_ = db.Close()
	needles := []string{"acme standup", errCanary}
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
		{"bad/id", ""},
		{"rec-diarizing", "acme standup diarizing.m4a"},
		{"rec-outside", "acme outside.m4a"},
		{"rec-queued", "acme standup queued.m4a"},
		{"rec-received", "acme standup received.m4a"},
		{"rec-summarizing", "acme standup summarizing.m4a"},
		{"rec-transcribing", "acme standup transcribing.m4a"},
	}
	if !equalPending(rep.PendingRecordings, want) || rep.SwiftState != "present" || rep.HubID != fixtureHubID || rep.Identity != "none" || rep.Step != "" {
		t.Fatalf("status before = %+v", rep)
	}
	killAt(t, "migrate")
	if _, err := f.run(t); err == nil {
		t.Fatal("no kill")
	}
	if rep, _ = Status(f.mobile, f.hub); !equalPending(rep.PendingRecordings, want) || rep.Step != StepRecordings || rep.SwiftState != "present" {
		t.Fatalf("status before the step = %+v", rep)
	}
	f.mustRun(t)
	rep, err = Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.PendingRecordings) != 0 || rep.PendingRecordings == nil || rep.SwiftState != "absent" || rep.Step != StepDone ||
		rep.Imported != wantCounts {
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
	if k.Count != 5 || !k.RemoveAt.Equal(f.now.Add(31*24*time.Hour)) || k.Dir != f.rec {
		t.Fatalf("kept = %+v", k)
	}
	_ = os.Remove(filepath.Join(f.rec, "rec-queued.m4a"))
	if k, _ := Kept(context.Background(), st, f.rec); k.Count != 4 {
		t.Fatalf("kept after one file went = %+v", k)
	}
}
