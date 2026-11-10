package sources

import (
	"fmt"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/db"
)

// A session being deleted (delete_requested_at, #1716) leaves the phone as
// if it were deleted: spec §4 "Readers of a row being deleted".

// markDeleting sets delete_requested_at the way the Desktop, its only
// writer, does.
func markDeleting(t *testing.T, d *db.DB, id int64) {
	t.Helper()
	exec(t, d, `UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, dbStamp(time.Now()), id)
}

func TestTerminalSessionSlice_HidesDeletingRow(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	kept := insertSession(t, r.d, project, sessionSeed{})
	deleting := insertSession(t, r.d, project, sessionSeed{})
	markDeleting(t, r.d, deleting)
	src := r.source([]int64{kept, deleting}, time.Time{}, nil)
	if got := payloads(t, src); len(got) != 1 || got[kept] == nil {
		t.Fatalf("published %v, want only %d", sessionIDs(got), kept)
	}
	if c := countsOf(t, r.d, src)[project]; c.Working+c.Waiting+c.NeedsApproval+c.Finished+c.Failed+c.Stopped+c.NotRunning != 1 {
		t.Errorf("counts = %+v, want the deleting session left out", c)
	}
}

func TestPermissionRequestSlice_HidesDeletingRow(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	kept := seedSession(t, d, wb, "claude")
	deleting := seedSession(t, d, wb, "claude")
	keptReq := insertRequest(t, d, reqSeed{session: kept, workbench: wb})
	insertRequest(t, d, reqSeed{session: deleting, workbench: wb})
	markDeleting(t, d, deleting)
	got := payloadsByKey(t, permSource(d, livenessOf(true, kept, deleting)))
	if len(got) != 1 || got[strconv.FormatInt(keptReq, 10)] == nil {
		t.Fatalf("published %v, want only request %d", got, keptReq)
	}
}

func TestTargetSlice_HidesDeletingSession(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	project := insertWorkbench(t, d, "acme", "/tmp/acme")
	target := insertTarget(t, d, project, targetSeed{})
	kept := insertSession(t, d, project, sessionSeed{target: &target, lastActive: now.Add(-time.Minute)})
	deleting := insertSession(t, d, project, sessionSeed{target: &target, lastActive: now})
	linked := insertSession(t, d, project, sessionSeed{lastActive: now})
	linkSession(t, d, linked, target)
	markDeleting(t, d, deleting)
	markDeleting(t, d, linked)
	if got := ids(targetPayloads(t, d)[target]["session_ids"]); fmt.Sprint(got) != fmt.Sprint([]int64{kept}) {
		t.Errorf("session_ids = %v, want only %d", got, kept)
	}
}

// A deleting session's activity does not rank its workbench.
func TestWorkbenchSlice_IgnoresDeletingSessionActivity(t *testing.T) {
	d := db.OpenTestDB(t)
	now := time.Now()
	older := insertWorkbench(t, d, "a", "/tmp/a")
	newer := insertWorkbench(t, d, "b", "/tmp/b")
	insertSession(t, d, older, sessionSeed{lastActive: now.Add(-time.Hour)})
	deleting := insertSession(t, d, newer, sessionSeed{lastActive: now})
	insertSession(t, d, newer, sessionSeed{lastActive: now.Add(-2 * time.Hour)})
	full, _, _, _ := rowIDs(t, d)
	if fmt.Sprint(full) != fmt.Sprint([]int64{newer, older}) {
		t.Fatalf("order before = %v", full)
	}
	markDeleting(t, d, deleting)
	full, light, _, _ := rowIDs(t, d)
	if want := fmt.Sprint([]int64{older, newer}); fmt.Sprint(full) != want || fmt.Sprint(light) != want {
		t.Errorf("order = %v / light %v, want %s", full, light, want)
	}
}
