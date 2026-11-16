package db

import (
	"testing"
	"time"
)

func TestWatchmanKnownKeys(t *testing.T) {
	d := openTestDB(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	if err := d.UpsertWatchmanPrecedents(tx, []WatchmanPrecedent{
		{WorkbenchID: wb, Source: "git", SourceKey: "commit:a", Category: "finish", DecidedAt: at, Weight: 1},
		{WorkbenchID: wb, Source: "turn", SourceKey: "commit:b", Category: "finish", DecidedAt: at, Weight: 1},
	}); err != nil {
		t.Fatal(err)
	}
	if err := d.MarkWatchmanSkippedKeys(tx, wb, "git", []string{"commit:d", "commit:d"}, at); err != nil {
		t.Fatal(err)
	}
	if err := d.MarkWatchmanSkippedKeys(tx, wb, "turn", []string{"commit:c"}, at); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	got, err := d.WatchmanKnownKeys(wb, "git", []string{"commit:a", "commit:b", "commit:c", "commit:d", "commit:e"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || !got["commit:a"] || !got["commit:d"] {
		t.Fatalf("got %v", got)
	}
	if got, err := d.WatchmanKnownKeys(wb, "git", nil); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	other, err := d.CreateWorkbench("acme-2", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if got, err := d.WatchmanKnownKeys(other, "git", []string{"commit:a", "commit:d"}); err != nil || len(got) != 0 {
		t.Fatalf("another workbench sees no keys: %v %v", got, err)
	}
}
