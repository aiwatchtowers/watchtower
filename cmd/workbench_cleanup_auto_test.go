package cmd

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"watchtower/internal/sessionstart"
)

// TestLiveRows: no session host answering is no live run; any other
// failure is an error (the pass then applies nothing); runs become rows.
func TestLiveRows(t *testing.T) {
	live, err := liveRows(nil, fmt.Errorf("%w: dial", sessionstart.ErrHostNotRunning))
	if err != nil || len(live) != 0 {
		t.Fatalf("no host: %v, %v", live, err)
	}
	if _, err := liveRows(nil, errors.New("listing the session host: broken")); err == nil {
		t.Fatal("a failed list is not an error")
	}
	live, err = liveRows(map[int64]time.Time{4: {}, 9: {}}, nil)
	if err != nil || !live[4] || !live[9] || len(live) != 2 {
		t.Fatalf("runs: %v, %v", live, err)
	}
}

// TestCleanupRequest_PruneBuildsOnlyForAnUnnamedApply (#2131): only an
// apply that names no item asks to drop kept worktrees' build output.
func TestCleanupRequest_PruneBuildsOnlyForAnUnnamedApply(t *testing.T) {
	noEnv := func(string) (string, bool) { return "", false }
	for name, tc := range map[string]struct {
		f    cleanupFlags
		want bool
	}{
		"plan":        {f: cleanupFlags{session: 5}},
		"apply":       {f: cleanupFlags{session: 5, apply: true}, want: true},
		"named apply": {f: cleanupFlags{session: 5, apply: true, items: []string{"branch:x"}}},
	} {
		req, err := cleanupRequest(tc.f, true, noEnv)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if req.PruneBuilds != tc.want {
			t.Errorf("%s: PruneBuilds = %v, want %v", name, req.PruneBuilds, tc.want)
		}
	}
}
