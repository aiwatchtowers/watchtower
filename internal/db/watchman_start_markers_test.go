package db

import (
	"os"
	"path/filepath"
	"testing"
)

// TestWatchmanStartMarkersGolden pins the owed-start markers the Desktop
// reads too (WatchmanItem.startOwedErrors reads the same file): -update
// rewrites it; a change without -update fails.
func TestWatchmanStartMarkersGolden(t *testing.T) {
	got := WatchmanStartPending + "\n" + WatchmanStartClaimed + "\n"
	path := filepath.Join("testdata", "watchman_start_markers.golden")
	if *updateGolden {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run go test ./internal/db -run TestWatchmanStartMarkersGolden -update)", err)
	}
	if string(want) != got {
		t.Fatalf("start markers changed:\n got %q\nwant %q\n(run with -update, then the Swift side follows)", got, want)
	}
}
