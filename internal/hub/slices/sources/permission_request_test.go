package sources

import (
	"context"
	"database/sql"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/rivo/uniseg"
)

// Go twins of PermissionRequestSliceTests: the pending requests of live
// board Claude sessions in the published workbenches, and the expiry of the
// requests no hook waits on any more.

var permNow = time.Unix(1_800_000_000, 0).UTC()

func livenessOf(settled bool, ids ...int64) func() Liveness {
	l := Liveness{Runs: map[int64]time.Time{}, Settled: settled}
	for _, id := range ids {
		l.Runs[id] = permNow.Add(-10 * time.Minute)
	}
	return func() Liveness { return l }
}

func permSource(d *db.DB, live func() Liveness) *permissionSource {
	return PermissionRequest(d, live, func() time.Time { return permNow }).(*permissionSource)
}

type reqSeed struct {
	session, workbench int64
	summary, status    string
	age                time.Duration
	clipped            bool
}

func insertRequest(t *testing.T, d *db.DB, r reqSeed) int64 {
	t.Helper()
	if r.summary == "" {
		r.summary = "git status"
	}
	if r.status == "" {
		r.status = "pending"
	}
	if r.age == 0 {
		r.age = 5 * time.Second
	}
	return execID(t, d, `INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
		VALUES (?, ?, 'Bash', ?, ?, ?, ?)`, r.session, r.workbench, r.summary, r.clipped, r.status, db.AgentStateStamp(permNow.Add(-r.age)))
}

func requestStatus(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	var s string
	if err := d.QueryRow(`SELECT status FROM permission_requests WHERE id = ?`, id).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func expire(t *testing.T, d *db.DB, live func() Liveness) int64 {
	t.Helper()
	n, err := expirePermissionRequests(context.Background(), d, live(), permNow)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// readOnly is a pass's read alone (no expiry write).
func readOnly(t *testing.T, d *db.DB, live func() Liveness) map[string]bool {
	t.Helper()
	var rows []pendingRequest
	err := readTx(context.Background(), d, func(tx *sql.Tx) error {
		var err error
		rows, err = pendingRequests(context.Background(), tx, live(), permNow)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, r := range rows {
		out[strconv.FormatInt(r.ID, 10)] = true
	}
	return out
}

func TestOnlyPendingRowsOfLiveBoardSessionsArePublished(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "Acme")
	live := seedSession(t, d, wb, "claude")
	gone := seedSession(t, d, wb, "claude")
	codex := seedSession(t, d, wb, "codex")
	pending := insertRequest(t, d, reqSeed{session: live, workbench: wb, summary: "git push origin main\nPush"})
	insertRequest(t, d, reqSeed{session: live, workbench: wb, status: "answered_on_mac", age: time.Minute})
	insertRequest(t, d, reqSeed{session: live, workbench: wb, status: "allowed", age: 90 * time.Second})
	insertRequest(t, d, reqSeed{session: gone, workbench: wb})
	insertRequest(t, d, reqSeed{session: codex, workbench: wb})

	got := payloadsByKey(t, permSource(d, livenessOf(true, live, codex)))
	if len(got) != 1 {
		t.Fatalf("published %v", got)
	}
	p := got[strconv.FormatInt(pending, 10)]
	assertKitKeys(t, p, "permission_request.json", "summary_clipped")
	if p["session_id"] != float64(live) || p["workbench_id"] != float64(wb) || p["tool_name"] != "Bash" ||
		p["summary"] != "git push origin main\nPush" || p["summary_clipped"] != nil || p["status"] != nil || p["decided_by"] != nil {
		t.Errorf("payload %v", p)
	}
}

func TestPermissionRequestAWorkbenchThatIsNotPublishedPublishesNothing(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	insertRequest(t, d, reqSeed{session: s, workbench: wb})
	execID(t, d, `PRAGMA foreign_keys = OFF`)
	execID(t, d, `DELETE FROM projects`)
	if got := payloadsByKey(t, permSource(d, livenessOf(true, s))); len(got) != 0 {
		t.Fatalf("published %v", got)
	}
}

func TestPermissionRequestALongSummaryIsClippedAndSaysSo(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	id := insertRequest(t, d, reqSeed{session: s, workbench: wb, summary: strings.Repeat("a", 2001)})
	p := payloadsByKey(t, permSource(d, livenessOf(true, s)))[strconv.FormatInt(id, 10)]
	if sum, _ := p["summary"].(string); uniseg.GraphemeClusterCount(sum) != PermissionMaxSummary || p["summary_clipped"] != true {
		t.Fatalf("payload %v", p["summary_clipped"])
	}
}

// The hook cut the summary at 2000 runes (Go's flag): the wire says so,
// though the text fits the wire's own cap.
func TestProj21_GoClippedFlagReachesTheWire(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	id := insertRequest(t, d, reqSeed{session: s, workbench: wb, summary: "echo aaa", clipped: true})
	p := payloadsByKey(t, permSource(d, livenessOf(true, s)))[strconv.FormatInt(id, 10)]
	if p["summary"] != "echo aaa" || p["summary_clipped"] != true {
		t.Fatalf("payload %v", p)
	}
	if _, clipped := WireSummary("echo aaa", true); !clipped {
		t.Error("Go's flag lost")
	}
	if _, clipped := WireSummary("echo aaa", false); clipped {
		t.Error("clipped without a reason")
	}
}

// A pending row older than the hook timeout, or of a session that is no
// longer live, has no reader: the pass marks it expired and never
// publishes it.
func TestPermissionRequestOldOrOrphanPendingRowsExpireOnThePass(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	live := seedSession(t, d, wb, "claude")
	other := seedSession(t, d, wb, "claude")
	gone := seedSession(t, d, wb, "claude")
	fresh := insertRequest(t, d, reqSeed{session: live, workbench: wb})
	old := insertRequest(t, d, reqSeed{session: other, workbench: wb, age: PermissionMaxAge + time.Second})
	atLimit := insertRequest(t, d, reqSeed{session: other, workbench: wb, age: PermissionMaxAge})
	orphan := insertRequest(t, d, reqSeed{session: gone, workbench: wb})
	allowed := insertRequest(t, d, reqSeed{session: gone, workbench: wb, status: "allowed"})
	lv := livenessOf(true, live, other)
	want := map[string]bool{strconv.FormatInt(fresh, 10): true, strconv.FormatInt(atLimit, 10): true}

	if got := readOnly(t, d, lv); len(got) != 2 || !got[strconv.FormatInt(fresh, 10)] || !got[strconv.FormatInt(atLimit, 10)] {
		t.Fatalf("the read alone published %v", got)
	}
	if n := expire(t, d, lv); n != 2 {
		t.Fatalf("expired %d, want 2", n)
	}
	for id, st := range map[int64]string{fresh: "pending", atLimit: "pending", old: "expired", orphan: "expired", allowed: "allowed"} {
		if got := requestStatus(t, d, id); got != st {
			t.Errorf("request %d: %s, want %s", id, got, st)
		}
	}
	var decided string
	if err := d.QueryRow(`SELECT decided_at FROM permission_requests WHERE id = ?`, old).Scan(&decided); err != nil || decided != db.AgentStateStamp(permNow) {
		t.Errorf("decided_at %q (%v)", decided, err)
	}
	got := payloadsByKey(t, permSource(d, lv))
	if len(got) != len(want) {
		t.Errorf("published %v", keysOfItems(got))
	}
	if n := expire(t, d, lv); n != 0 {
		t.Errorf("nothing left to expire, yet %d", n)
	}
}

func keysOfItems(m map[string]map[string]any) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

// Before liveness settles only the age expires a row; a young row of a
// session not live yet is only hidden.
func TestPermissionRequestBeforeLivenessSettlesOnlyTheAgeExpires(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	young := insertRequest(t, d, reqSeed{session: s, workbench: wb})
	old := insertRequest(t, d, reqSeed{session: s, workbench: wb, age: PermissionMaxAge + time.Second})
	unsettled := livenessOf(false)
	if n := expire(t, d, unsettled); n != 1 {
		t.Fatalf("expired %d", n)
	}
	if requestStatus(t, d, young) != "pending" || requestStatus(t, d, old) != "expired" {
		t.Fatal("before settling: wrong rows expired")
	}
	if got := readOnly(t, d, unsettled); len(got) != 0 {
		t.Fatal("published while its session is not live")
	}
	if n := expire(t, d, livenessOf(true)); n != 1 || requestStatus(t, d, young) != "expired" {
		t.Fatalf("once settled the not-live rule applies (%d)", n)
	}
}

// Ruling 1: the expiry age is the hook's own timeout.
func TestPermissionRequestTheExpiryAgeIsTheHookTimeout(t *testing.T) {
	if PermissionMaxAge != 86_400*time.Second || PermissionMaxSummary != 2000 {
		t.Fatal(PermissionMaxAge, PermissionMaxSummary)
	}
}

// A publish pass (Items) runs the expiry.
func TestPermissionRequestAPassRunsTheExpiry(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	id := insertRequest(t, d, reqSeed{session: s, workbench: wb})
	payloadsByKey(t, permSource(d, livenessOf(true)))
	if requestStatus(t, d, id) != "expired" {
		t.Fatal("the pass did not expire a not-live session's request")
	}
}

// A nil Liveness func reads as nothing live and not settled: requests are
// hidden, and only their age expires them.
func TestPermissionRequestNilLivenessIsUnsettled(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	s := seedSession(t, d, wb, "claude")
	young := insertRequest(t, d, reqSeed{session: s, workbench: wb})
	old := insertRequest(t, d, reqSeed{session: s, workbench: wb, age: PermissionMaxAge + time.Second})
	if got := payloadsByKey(t, permSource(d, nil)); len(got) != 0 {
		t.Fatalf("published %v", got)
	}
	if requestStatus(t, d, young) != "pending" || requestStatus(t, d, old) != "expired" {
		t.Fatal("nil liveness expired by liveness, or not by age")
	}
	if got := payloadsByKey(t, WorkAlert(WorkAlertConfig{DB: d, Store: newAlertRig(t).st})); len(got) != 0 {
		t.Fatalf("work alerts with nil liveness: %v", got)
	}
}
