package db

import (
	"database/sql"
	"errors"
	"testing"
)

func seedReviewSession(t *testing.T, d *DB) (projectID, sessionID int64) {
	t.Helper()
	projectID, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var res sql.Result
	res, err = d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', '/tmp/wb-review', 'uuid')`, projectID)
	if err != nil {
		t.Fatal(err)
	}
	sessionID, _ = res.LastInsertId()
	return
}

func TestReview04_SendIsGuardedAndStoredBeforeTheLine(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	r := ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/tmp/wb-review", BaseSHA: "b", TreeSHA: "t1"}
	id, err := d.CreateReviewRound(r)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.CreateReviewRound(r); err == nil {
		t.Fatal("second open round for the same session was accepted")
	}
	if _, err := d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body) VALUES (?, 'a.go', 3, 3, 'x', 'fix')`, id); err != nil {
		t.Fatal(err)
	}
	n, ok, err := d.SendReviewRound(pid, id)
	if err != nil || !ok || n != 1 {
		t.Fatalf("send = %d %v %v", n, ok, err)
	}
	if _, ok, _ := d.SendReviewRound(pid, id); ok {
		t.Fatal("a sent round was sent again")
	}
	assertSentRoundState(t, d, pid, sid, id)
	if _, err := d.CreateReviewRound(r); err != nil {
		t.Fatalf("a new round after send: %v", err)
	}
}

// assertSentRoundState checks what a sent round leaves behind: its comments
// marked sent, no more tree updates, one waiting line, delivery limited to its
// own workbench, and it being the session's last sent round.
func assertSentRoundState(t *testing.T, d *DB, pid, sid, id int64) {
	t.Helper()
	cs, _ := d.ReviewRoundComments(id)
	if len(cs) != 1 || cs[0].Status != "sent" {
		t.Fatalf("comments = %+v", cs)
	}
	if err := d.UpdateReviewRoundTree(id, "t2"); !errors.Is(err, ErrReviewRoundNotOpen) {
		t.Fatalf("tree update on a sent round: %v", err)
	}
	waiting, _ := d.ReviewRoundsWaiting(pid, sid)
	if len(waiting) != 1 {
		t.Fatalf("waiting = %+v", waiting)
	}
	if ok, _ := d.MarkReviewRoundDelivered(pid, id); !ok {
		t.Fatal("deliver failed")
	}
	if ok, _ := d.MarkReviewRoundDelivered(pid+1, id); ok {
		t.Fatal("another workbench delivered the round")
	}
	last, _ := d.LastSentReviewRound(pid, sid)
	if last == nil || last.ID != id {
		t.Fatalf("last sent = %+v", last)
	}
}

func TestReviewRounds_RefusedSendFromAnotherWorkbenchWritesNothing(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	a, _ := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	if _, err := d.Exec(`INSERT INTO review_comments (round_id, body) VALUES (?, 'mine')`, a); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := d.SendReviewRound(pid+100, a); ok || err != nil {
		t.Fatalf("send from another workbench: %v %v", ok, err)
	}
	cs, _ := d.ReviewRoundComments(a)
	if cs[0].Status != "draft" {
		t.Fatal("a refused send changed a draft")
	}
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }

func TestReviewRounds_SendIncludesCarried(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	id, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	if err != nil {
		t.Fatal(err)
	}
	for _, st := range []string{"carried", "outdated", "draft"} {
		if _, err := d.Exec(`INSERT INTO review_comments (round_id, body, status) VALUES (?, ?, ?)`, id, st, st); err != nil {
			t.Fatal(err)
		}
	}
	n, ok, err := d.SendReviewRound(pid, id)
	if err != nil || !ok || n != 2 {
		t.Fatalf("send = %d %v %v", n, ok, err)
	}
	cs, _ := d.ReviewRoundComments(id)
	got := map[string]string{}
	for _, c := range cs {
		got[c.Body] = c.Status
	}
	if got["carried"] != "sent" || got["draft"] != "sent" || got["outdated"] != "outdated" {
		t.Fatalf("statuses = %v", got)
	}
}
