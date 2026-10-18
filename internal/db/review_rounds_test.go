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

func TestReplyReviewComment_RepliesResolvesAndFollowsTheOpenCopy(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	cid, copies := seedSentCommentWithCopies(t, d, pid, sid)
	carried, outdated, ownerResolved := copies[0], copies[1], copies[2]

	ok, err := d.ReplyReviewComment(pid, cid, "looked at it", false)
	if err != nil || !ok {
		t.Fatalf("reply = %v %v", ok, err)
	}
	assertRepliedUnresolved(t, d, []int64{cid, carried, outdated}, "looked at it")
	assertOwnerResolvedUntouched(t, d, ownerResolved)

	ok, err = d.ReplyReviewComment(pid, cid, "fixed", true)
	if err != nil || !ok {
		t.Fatalf("resolve = %v %v", ok, err)
	}
	for _, id := range []int64{cid, carried, outdated} {
		if st, reply, _ := reviewCommentState(t, d, id); st != "resolved" || reply != "fixed" {
			t.Fatalf("comment %d = %q %q", id, st, reply)
		}
	}
	assertOwnerResolvedUntouched(t, d, ownerResolved)

	// resolved:false never reopens an agent- or owner-resolved comment.
	if ok, err = d.ReplyReviewComment(pid, cid, "one more word", false); err != nil || !ok {
		t.Fatalf("second reply = %v %v", ok, err)
	}
	if st, reply, _ := reviewCommentState(t, d, cid); st != "resolved" || reply != "one more word" {
		t.Fatalf("comment = %q %q", st, reply)
	}
}

// seedSentCommentWithCopies sends a round holding one comment, opens the
// next round and gives it a carried, an outdated and an owner-resolved copy
// of that comment. It returns the comment id and the three copies in order.
func seedSentCommentWithCopies(t *testing.T, d *DB, pid, sid int64) (int64, [3]int64) {
	t.Helper()
	sent, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t1"})
	if err != nil {
		t.Fatal(err)
	}
	res, err := d.Exec(`INSERT INTO review_comments (round_id, path, body) VALUES (?, 'a.go', 'fix')`, sent)
	if err != nil {
		t.Fatal(err)
	}
	cid, _ := res.LastInsertId()
	if _, ok, err := d.SendReviewRound(pid, sent); err != nil || !ok {
		t.Fatalf("send = %v %v", ok, err)
	}
	open, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t2"})
	if err != nil {
		t.Fatal(err)
	}
	copyOf := func(status string) int64 {
		res, err := d.Exec(`INSERT INTO review_comments (round_id, path, body, status, carried_from) VALUES (?, 'a.go', 'fix', ?, ?)`, open, status, cid)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		return id
	}
	carried, outdated, ownerResolved := copyOf("carried"), copyOf("outdated"), copyOf("resolved")
	return cid, [3]int64{carried, outdated, ownerResolved}
}

// reviewCommentState reads a comment's status and agent reply.
func reviewCommentState(t *testing.T, d *DB, id int64) (status, reply string, at sql.NullString) {
	t.Helper()
	if err := d.QueryRow(`SELECT status, agent_reply, agent_reply_at FROM review_comments WHERE id = ?`, id).Scan(&status, &reply, &at); err != nil {
		t.Fatal(err)
	}
	return
}

// assertRepliedUnresolved checks each comment carries reply, stamped, and is
// not resolved.
func assertRepliedUnresolved(t *testing.T, d *DB, ids []int64, want string) {
	t.Helper()
	for _, id := range ids {
		st, reply, at := reviewCommentState(t, d, id)
		if reply != want || !at.Valid {
			t.Fatalf("comment %d reply = %q %v", id, reply, at)
		}
		if st == "resolved" {
			t.Fatalf("comment %d resolved by an unresolved reply", id)
		}
	}
}

// assertOwnerResolvedUntouched checks the owner-resolved copy got no reply.
func assertOwnerResolvedUntouched(t *testing.T, d *DB, id int64) {
	t.Helper()
	if st, reply, _ := reviewCommentState(t, d, id); st != "resolved" || reply != "" {
		t.Fatalf("owner-resolved copy touched: %q %q", st, reply)
	}
}

func TestReplyReviewComment_RefusesDraftsOpenRoundsAndOtherWorkbenches(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	round, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	if err != nil {
		t.Fatal(err)
	}
	draft := insertRoundComment(t, d, round, "draft one", "draft")
	inOpen := insertRoundComment(t, d, round, "sent one", "sent")
	for name, c := range map[string]struct {
		project, id int64
	}{"draft in open round": {pid, draft}, "sent status in an open round": {pid, inOpen}, "unknown": {pid, 9999}} {
		ok, err := d.ReplyReviewComment(c.project, c.id, "x", true)
		if err != nil || ok {
			t.Fatalf("%s: ok=%v err=%v", name, ok, err)
		}
	}
	if _, ok, err := d.SendReviewRound(pid, round); err != nil || !ok {
		t.Fatalf("send = %v %v", ok, err)
	}
	if ok, err := d.ReplyReviewComment(other, inOpen, "x", true); err != nil || ok {
		t.Fatalf("other workbench: ok=%v err=%v", ok, err)
	}
	if _, err := d.Exec(`UPDATE review_comments SET status = 'draft' WHERE id = ?`, draft); err != nil {
		t.Fatal(err)
	}
	if ok, err := d.ReplyReviewComment(pid, draft, "x", true); err != nil || ok {
		t.Fatalf("draft: ok=%v err=%v", ok, err)
	}
	assertNoReplyWritten(t, d)
}

// insertRoundComment adds a comment with body and status to round.
func insertRoundComment(t *testing.T, d *DB, round int64, body, status string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO review_comments (round_id, body, status) VALUES (?, ?, ?)`, round, body, status)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

// assertNoReplyWritten checks no comment carries an agent reply.
func assertNoReplyWritten(t *testing.T, d *DB) {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM review_comments WHERE agent_reply <> ''`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("replies written = %d %v", n, err)
	}
}
