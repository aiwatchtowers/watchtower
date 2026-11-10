package sources

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"watchtower/internal/hub/state"
)

// TestHubMovedTextPinned: the text a hub_moved job shows is the Decisions
// string (plan go-hub phase 3, Decision 3) byte for byte.
func TestHubMovedTextPinned(t *testing.T) {
	const want = "Watchtower was updated while this recording was being transcribed. The audio is kept on your Mac; send it again if you still have it on this iPhone."
	if HubMovedText != want {
		t.Fatalf("HubMovedText = %q", HubMovedText)
	}
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 0)
	err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := state.ImportRecordingJobTx(tx, state.RecordingJob{
			UploadID: "up-1", Status: state.RecordingFailed, ErrorClass: state.ClassHubMoved, CreatedAt: t0, FinishedAt: t0,
		})
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	p := jobPayloads(t, st, t0)["up-1"]
	if p["status"] != "failed" || p["error"] != want {
		t.Fatalf("hub_moved job = %v", p)
	}
	// Any other class still publishes the class only.
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := state.ImportRecordingJobTx(tx, state.RecordingJob{
			UploadID: "up-2", Status: state.RecordingFailed, ErrorClass: "disk_full", CreatedAt: t0, FinishedAt: t0,
		})
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if p := jobPayloads(t, st, t0)["up-2"]; p["error"] != "disk_full" {
		t.Fatalf("other class = %v", p)
	}
}
