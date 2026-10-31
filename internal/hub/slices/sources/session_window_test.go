package sources

import (
	"context"
	"testing"
	"time"
)

// The windows the chat and report request handlers read: published = an
// agent session of a published workbench; report window = published and
// live or active in the last 7 days (SessionReportSlice.window).
func TestSessionWindows(t *testing.T) {
	r := newSessionRig(t)
	wb := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	recent := insertSession(t, r.d, wb, sessionSeed{lastActive: r.now.Add(-time.Hour)})
	old := insertSession(t, r.d, wb, sessionSeed{lastActive: r.now.Add(-8 * 24 * time.Hour)})
	oldLive := insertSession(t, r.d, wb, sessionSeed{kind: "codex", lastActive: r.now.Add(-8 * 24 * time.Hour)})
	shell := insertSession(t, r.d, wb, sessionSeed{kind: "shell"})
	src := r.source([]int64{oldLive}, time.Time{}, nil)
	ctx := context.Background()

	for _, c := range []struct {
		id              int64
		published, inRp bool
	}{
		{recent, true, true}, {old, true, false}, {oldLive, true, true}, {shell, false, false}, {9999, false, false},
	} {
		pub, err := src.Published(ctx, c.id)
		if err != nil {
			t.Fatal(err)
		}
		in, err := src.InReportWindow(ctx, c.id)
		if err != nil {
			t.Fatal(err)
		}
		if pub != c.published || in != c.inRp {
			t.Errorf("session %d: published %v, in report window %v; want %v, %v", c.id, pub, in, c.published, c.inRp)
		}
	}
}
