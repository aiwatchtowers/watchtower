package db

import (
	"errors"
	"testing"
	"time"
)

func openPermissionFixture(t *testing.T) (*DB, int64, int64) {
	t.Helper()
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	row := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	return d, pid, row
}

func TestOpenPermissionRequestSetsApprovalAndInserts(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	at := time.Now().UTC().Truncate(time.Millisecond)
	id, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "ls -la", false, at, AgentOrder{})
	if err != nil {
		t.Fatal(err)
	}
	ts, err := d.GetTerminalSession(row)
	if err != nil {
		t.Fatal(err)
	}
	if !ts.AgentState.Valid || ts.AgentState.String != "approval" || !ts.AgentStateAt.Equal(at) {
		t.Fatalf("state = %+v at %v, want approval at %v", ts.AgentState, ts.AgentStateAt, at)
	}
	got, err := d.GetPermissionRequest(id)
	if err != nil {
		t.Fatal(err)
	}
	assertNewPendingRequest(t, got, row, pid, at)
	if _, err := d.GetPermissionRequest(id + 100); !errors.Is(err, ErrPermissionRequestNotFound) {
		t.Fatalf("missing row err = %v", err)
	}
}

// assertNewPendingRequest checks a just-opened `ls -la` Bash request.
func assertNewPendingRequest(t *testing.T, got *PermissionRequest, row, pid int64, at time.Time) {
	t.Helper()
	if got.Status != PermissionPending || got.ToolName != "Bash" || got.Summary != "ls -la" ||
		got.SummaryClipped || got.TerminalSessionID != row || got.WorkbenchID != pid || got.DecidedAt.Valid || got.DecidedBy.Valid {
		t.Fatalf("row = %+v", got)
	}
	if !got.CreatedAt.Equal(at) {
		t.Fatalf("created_at = %v, want %v", got.CreatedAt, at)
	}
}

func TestOpenPermissionRequestInsertsWhenTheStateGuardHoldsBack(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	at := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "a", false, at, AgentOrder{}); err != nil {
		t.Fatal(err)
	}
	// The same state again: the guard writes nothing, the row still lands.
	id, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "b", false, at.Add(time.Second), AgentOrder{})
	if err != nil || id == 0 {
		t.Fatalf("id=%d err=%v", id, err)
	}
}

func TestInsertPermissionRequestClosesTheOlderPending(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	at := time.Now().UTC().Truncate(time.Millisecond)
	first, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "a", false, at, AgentOrder{})
	if err != nil {
		t.Fatal(err)
	}
	second, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "b", false, at.Add(time.Second), AgentOrder{})
	if err != nil {
		t.Fatal(err)
	}
	a, err := d.GetPermissionRequest(first)
	if err != nil {
		t.Fatal(err)
	}
	b, err := d.GetPermissionRequest(second)
	if err != nil {
		t.Fatal(err)
	}
	if a.Status != PermissionAnsweredOnMac || b.Status != PermissionPending {
		t.Fatalf("first=%s second=%s", a.Status, b.Status)
	}
}

func TestClosePermissionRequestIsCompareAndSet(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	at := time.Now().UTC().Truncate(time.Millisecond)
	id, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "a", false, at, AgentOrder{})
	if err != nil {
		t.Fatal(err)
	}
	ok, err := d.ClosePermissionRequest(id, PermissionAllowed, at.Add(time.Second))
	if err != nil || !ok {
		t.Fatalf("first close ok=%v err=%v", ok, err)
	}
	ok, err = d.ClosePermissionRequest(id, PermissionDenied, at.Add(2*time.Second))
	if err != nil || ok {
		t.Fatalf("second close ok=%v err=%v", ok, err)
	}
	got, err := d.GetPermissionRequest(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != PermissionAllowed || !got.DecidedAt.Valid || got.DecidedAt.String != AgentStateStamp(at.Add(time.Second)) {
		t.Fatalf("row = %+v", got)
	}
}

func TestPermissionRequestCheckRejectsUnknownStatus(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	_, err := d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, status, created_at)
		VALUES (?, ?, 'maybe', 'x')`, row, pid)
	if err == nil {
		t.Fatal("unknown status accepted")
	}
}

// A cut-short summary is stored as such (the phone then offers Deny only).
func TestOpenPermissionRequestStoresTheClippedFlag(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	at := time.Now().UTC().Truncate(time.Millisecond)
	id, err := d.OpenPermissionRequest(row, pid, agentStateUUID, "Bash", "a", true, at, AgentOrder{})
	if err != nil {
		t.Fatal(err)
	}
	got, err := d.GetPermissionRequest(id)
	if err != nil {
		t.Fatal(err)
	}
	if !got.SummaryClipped {
		t.Fatalf("row = %+v, want summary_clipped", got)
	}
}

// Go writes only agent-state stamps: any other created_at is an error, not
// a zero time that would read as older than every state change.
func TestGetPermissionRequestRefusesABadStamp(t *testing.T) {
	d, pid, row := openPermissionFixture(t)
	res, err := d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, status, created_at)
		VALUES (?, ?, 'pending', 'yesterday')`, row, pid)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.GetPermissionRequest(id); err == nil || errors.Is(err, ErrPermissionRequestNotFound) {
		t.Fatalf("err = %v, want a bad created_at error", err)
	}
}
