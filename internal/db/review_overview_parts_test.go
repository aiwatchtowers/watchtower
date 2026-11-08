package db

import (
	"testing"
	"time"
)

func TestReviewOverviewParts_PutGetAndReplace(t *testing.T) {
	d := openTestDB(t)
	pid, _ := seedReviewSession(t, d)
	now := time.Now().UTC().Truncate(time.Second)
	if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: pid, Hash: "h1", JSON: `{"a":1}`, Model: "m1"}, now); err != nil {
		t.Fatal(err)
	}
	if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: pid, Hash: "h2", JSON: `{"b":1}`, Model: "m1"}, now); err != nil {
		t.Fatal(err)
	}
	// The same hash is replaced, not duplicated.
	if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: pid, Hash: "h1", JSON: `{"a":2}`, Model: "m2"}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	got, err := d.ReviewOverviewParts(pid, []string{"h1", "h2", "missing"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("parts = %+v", got)
	}
	p := got["h1"]
	if p.JSON != `{"a":2}` || p.Model != "m2" || p.ProjectID != pid || p.Hash != "h1" || !p.CreatedAt.Equal(now.Add(time.Minute)) {
		t.Fatalf("h1 = %+v", p)
	}
	if got["h2"].JSON != `{"b":1}` {
		t.Fatalf("h2 = %+v", got["h2"])
	}
	// Another workbench never sees these rows; an empty list reads nothing.
	other, err := d.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if got, err := d.ReviewOverviewParts(other, []string{"h1"}); err != nil || len(got) != 0 {
		t.Fatalf("other workbench = %+v %v", got, err)
	}
	if got, err := d.ReviewOverviewParts(pid, nil); err != nil || len(got) != 0 {
		t.Fatalf("empty hashes = %+v %v", got, err)
	}
}

func TestReviewOverviewParts_ManyHashes(t *testing.T) {
	d := openTestDB(t)
	pid, _ := seedReviewSession(t, d)
	now := time.Now().UTC()
	hashes := make([]string, 0, 1200)
	for i := range 1200 {
		hashes = append(hashes, "h"+time.Duration(i).String())
	}
	for _, h := range []string{hashes[0], hashes[700], hashes[1199]} {
		if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: pid, Hash: h, JSON: "{}"}, now); err != nil {
			t.Fatal(err)
		}
	}
	got, err := d.ReviewOverviewParts(pid, hashes)
	if err != nil || len(got) != 3 {
		t.Fatalf("parts = %d %v", len(got), err)
	}
}

func TestReviewOverviewParts_PrunedAfter30Days(t *testing.T) {
	d := openTestDB(t)
	pid, _ := seedReviewSession(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	put := func(project int64, hash string, at time.Time) {
		t.Helper()
		if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: project, Hash: hash, JSON: "{}"}, at); err != nil {
			t.Fatal(err)
		}
	}
	put(pid, "old", now.Add(-31*24*time.Hour))
	put(pid, "young", now.Add(-29*24*time.Hour))
	put(other, "other-old", now.Add(-31*24*time.Hour))
	put(pid, "new", now)
	got, err := d.ReviewOverviewParts(pid, []string{"old", "young", "new"})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got["old"]; ok {
		t.Fatal("a 31-day-old part survived the next put")
	}
	if _, ok := got["young"]; !ok {
		t.Fatal("a 29-day-old part was pruned")
	}
	if _, ok := got["new"]; !ok {
		t.Fatal("the new part is missing")
	}
	// Pruning is per workbench: the other one's old row waits for its own put.
	if got, _ := d.ReviewOverviewParts(other, []string{"other-old"}); len(got) != 1 {
		t.Fatalf("another workbench's row was pruned: %+v", got)
	}
}

func TestReviewOverviewParts_CascadeOnWorkbenchDelete(t *testing.T) {
	d := openTestDB(t)
	pid, _ := seedReviewSession(t, d)
	if err := d.PutReviewOverviewPart(ReviewOverviewPart{ProjectID: pid, Hash: "h", JSON: "{}"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`DELETE FROM projects WHERE id = ?`, pid); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM review_overview_parts`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("rows after delete = %d %v", n, err)
	}
}
