package sources

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/state"
)

const jobDevice = "AAAAAAAA-0000-4000-8000-000000000001"

func jobPayloads(t *testing.T, st *state.Store, now time.Time) map[string]map[string]any {
	t.Helper()
	src, err := RecordingJob(st, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	items, err := src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, it := range items {
		out[it.ID] = decode(t, it.Payload)
	}
	return out
}

func TestRecordingJobProgress(t *testing.T) {
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 500_000_000)
	if err := st.QueueRecording("up-1", jobDevice, t0); err != nil {
		t.Fatal(err)
	}
	p := jobPayloads(t, st, t0)["up-1"]
	if p["status"] != "queued" || num(p["updated_at"]) != 1_800_000_000 {
		t.Errorf("queued = %v", p)
	}
	for _, k := range []string{"percent", "transcript_id", "error"} {
		if _, ok := p[k]; ok {
			t.Errorf("queued carries %s", k)
		}
	}
	if _, err := st.ClaimRecording("up-1", t0.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if p := jobPayloads(t, st, t0)["up-1"]; p["status"] != "transcribing" || num(p["updated_at"]) != 1_800_000_001 {
		t.Errorf("claimed = %v", p)
	}
	tid := int64(42)
	if _, err := st.FinishRecording("up-1", &tid, "", t0.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	if p := jobPayloads(t, st, t0)["up-1"]; p["status"] != "done" || num(p["transcript_id"]) != 42 {
		t.Errorf("done = %v", p)
	}
}

func TestRecordingJobFailedCarriesOnlyTheErrorClass(t *testing.T) {
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 0)
	_ = st.QueueRecording("up-1", jobDevice, t0)
	_, _ = st.ClaimRecording("up-1", t0)
	if _, err := st.FinishRecording("up-1", nil, "Disk full: /Users/x/rec.m4a", t0); err != nil {
		t.Fatal(err)
	}
	p := jobPayloads(t, st, t0)["up-1"]
	if p["status"] != "failed" || p["error"] != "other" || strings.Contains(fmt.Sprint(p), "Users") {
		t.Errorf("failed = %v", p)
	}
	if _, ok := p["transcript_id"]; ok {
		t.Error("a failed job has no transcript")
	}
}

func TestRecordingJobKeptSevenDaysAfterItEnded(t *testing.T) {
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 0)
	_ = st.QueueRecording("done", jobDevice, t0)
	_, _ = st.ClaimRecording("done", t0)
	tid := int64(1)
	_, _ = st.FinishRecording("done", &tid, "", t0)
	_ = st.QueueRecording("waiting", jobDevice, t0)
	week := 7 * 24 * time.Hour
	if got := jobPayloads(t, st, t0.Add(week)); got["done"] == nil || got["waiting"] == nil {
		t.Errorf("at exactly 7 days both stay: %v", got)
	}
	got := jobPayloads(t, st, t0.Add(week+time.Second))
	if got["done"] != nil {
		t.Error("7 days and 1 second after done the record is deleted")
	}
	if got["waiting"] == nil {
		t.Error("an unfinished job stays")
	}
}

func TestRecordingJobAtMost100LatestFirst(t *testing.T) {
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 0)
	for i := 0; i < 101; i++ {
		if err := st.QueueRecording(fmt.Sprintf("up-%03d", i), jobDevice, t0.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	got := jobPayloads(t, st, t0.Add(time.Hour))
	if len(got) != 100 || got["up-000"] != nil || got["up-100"] == nil {
		t.Errorf("%d jobs; the oldest must drop", len(got))
	}
}

func TestRecordingJobNeedsTheHubState(t *testing.T) {
	if _, err := RecordingJob(nil, nil); err == nil {
		t.Error("no store must be refused")
	}
}
