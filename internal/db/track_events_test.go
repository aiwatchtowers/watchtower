package db

import "testing"

func TestTrackEventsCRUD(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	tid, _ := d.CreateCustomTrack(Track{AssigneeUserID: "U1", Text: "watch", Instruction: "i"})

	id, err := d.InsertTrackEvent(TrackEvent{
		TrackID: int(tid), Summary: "refund approved",
		SourceType: "digest", SourceRefs: `["http://x"]`, ActionStatus: "none",
	})
	if err != nil || id == 0 {
		t.Fatalf("InsertTrackEvent: id=%d err=%v", id, err)
	}
	evs, err := d.GetTrackEvents(int(tid), 10)
	if err != nil || len(evs) != 1 || evs[0].Summary != "refund approved" {
		t.Fatalf("GetTrackEvents: %+v err=%v", evs, err)
	}
	sums, _ := d.GetTrackEventSummaries(int(tid), 10)
	if len(sums) != 1 {
		t.Fatalf("summaries: %v", sums)
	}
	// Deleting the track cascades events.
	if _, err := d.Exec(`DELETE FROM tracks WHERE id = ?`, tid); err != nil {
		t.Fatal(err)
	}
	evs, _ = d.GetTrackEvents(int(tid), 10)
	if len(evs) != 0 {
		t.Fatalf("events not cascaded: %d", len(evs))
	}
}
