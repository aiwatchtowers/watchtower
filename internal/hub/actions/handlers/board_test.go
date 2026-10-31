package handlers

import (
	"context"
	"database/sql"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
)

// Go twins of BoardHandlersTests: the owner's writer, the stale-view guard,
// the board scope and each refusal's reason. Desktop-only halves (the
// owner-write report to the Mac's notifier, isReporting, the CLI runner) have
// no Go counterpart: the Go hub writes as the owner (status_actor owner,
// PROJ-06) through the same queries `workbench target add` uses.

func (e *env) target(wb int64, parent int64, title string) int64 {
	e.t.Helper()
	p := sql.NullInt64{Int64: parent, Valid: parent != 0}
	return db.SeedTestWorkbenchTarget(e.t, e.db, wb, p, title)
}

// seedChain: leaf is the only child of mid, the only child of root.
func (e *env) seedChain() (wb, root, mid, leaf int64) {
	wb = e.workbench()
	root = e.target(wb, 0, "Plan")
	mid = e.target(wb, root, "Feature")
	leaf = e.target(wb, mid, "Task")
	return
}

func (e *env) seedTarget(status, priority string) (wb, t int64) {
	wb = e.workbench()
	t = e.target(wb, 0, "Task")
	e.exec(`UPDATE targets SET status = ?, priority = ? WHERE id = ?`, status, priority, t)
	return
}

func (e *env) statusAction(t, wb int64, to, from string) actions.Request {
	return e.request("board_target_status", id(t), map[string]any{"workbench_id": wb, "status": to, "from_status": from})
}

func (e *env) createAction(wb int64, text string, parent int64, intent string) actions.Request {
	p := map[string]any{"workbench_id": wb, "text": text, "intent": intent, "priority": "high"}
	if parent != 0 {
		p["parent_id"] = parent
	}
	return e.request("board_target_create", nil, p)
}

func (e *env) status(t int64) string { return e.scalar(`SELECT status FROM targets WHERE id = ?`, t) }

func (e *env) history(t int64) int {
	return e.count(`SELECT COUNT(*) FROM target_status_history WHERE target_id = ?`, t)
}

func (e *env) comments(t int64) int {
	return e.count(`SELECT COUNT(*) FROM project_comments WHERE target_id = ?`, t)
}

func (e *env) board(r actions.Request) actions.Outcome { return e.h.board(context.Background(), r) }

func wantApplied(t *testing.T, got actions.Outcome, key string, value any) {
	t.Helper()
	if got.Status != wire.StatusApplied || got.Result[key] != value {
		t.Fatalf("outcome = %+v, want applied %s=%v", got, key, value)
	}
}

// MARK: - Status

// PROJ-06: the phone's change is the owner's in the history; PROJ-05: the
// chain rolls up. (The Swift twin's "never notifies the Mac" half is the
// Desktop notifier's, keyed off this history actor in phase 3.)
func TestAStatusChangeIsTheOwnersAndRollsUp(t *testing.T) {
	e := newEnv(t)
	wb, root, _, leaf := e.seedChain()

	wantApplied(t, e.board(e.statusAction(leaf, wb, "done", "todo")), "status", "done")
	if a := e.scalar(`SELECT actor FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT 1`, leaf); a != "owner" {
		t.Fatalf("history actor = %q, want owner", a)
	}
	if s := e.status(root); s != "done" {
		t.Fatalf("root = %s, want done (PROJ-05 rollup)", s)
	}
}

func TestAStatusOnAGroupIsInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, _, mid, _ := e.seedChain()

	wantOutcome(t, e.board(e.statusAction(mid, wb, "done", "todo")), wire.StatusFailed, reasonInvalidParams)
	if e.status(mid) != "todo" {
		t.Fatal("a group's status is never written")
	}
}

func TestAStaleFromStatusIsAConflictWithTheCurrentStatus(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("in_review", "medium")
	before := e.history(tg)

	got := e.board(e.statusAction(tg, wb, "done", "todo"))

	wantOutcome(t, got, wire.StatusFailed, reasonConflict)
	if got.Result["current"] != "in_review" || got.Message != "Changed on the Mac to in_review" {
		t.Fatalf("outcome = %+v", got)
	}
	if e.status(tg) != "in_review" || e.history(tg) != before {
		t.Fatal("nothing written")
	}
}

func TestACurrentStatusEqualToTheRequestedOneIsAppliedWithoutAWrite(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("in_progress", "medium")
	before := e.history(tg)

	wantApplied(t, e.board(e.statusAction(tg, wb, "in_progress", "todo")), "status", "in_progress")
	if e.history(tg) != before {
		t.Fatal("no write, no history row")
	}
}

func TestAStatusOutsideTheEditableOnesIsInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	for _, bad := range []string{"active", "", "DONE"} {
		wantOutcome(t, e.board(e.statusAction(tg, wb, bad, "todo")), wire.StatusFailed, reasonInvalidParams)
	}
	if e.status(tg) != "todo" {
		t.Fatal("unchanged")
	}
}

func TestAStatusWithoutFromStatusIsInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	got := e.board(e.request("board_target_status", id(tg), map[string]any{"workbench_id": wb, "status": "done"}))
	wantOutcome(t, got, wire.StatusFailed, reasonInvalidParams)
	if e.status(tg) != "todo" {
		t.Fatal("unchanged")
	}
}

// MARK: - Priority

func TestAPriorityChangeIsWrittenAndReported(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	got := e.board(e.request("board_target_priority", id(tg),
		map[string]any{"workbench_id": wb, "priority": "high", "from_priority": "medium"}))
	wantApplied(t, got, "priority", "high")
	if p := e.scalar(`SELECT priority FROM targets WHERE id = ?`, tg); p != "high" {
		t.Fatalf("priority = %s", p)
	}
}

func TestAStalePriorityIsAConflictAndAnUnknownOneIsInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "low")
	prio := func(to, from string) actions.Outcome {
		return e.board(e.request("board_target_priority", id(tg),
			map[string]any{"workbench_id": wb, "priority": to, "from_priority": from}))
	}
	stale := prio("high", "medium")
	wantOutcome(t, stale, wire.StatusFailed, reasonConflict)
	if stale.Result["current"] != "low" {
		t.Fatalf("current = %v", stale.Result["current"])
	}
	wantOutcome(t, prio("urgent", "low"), wire.StatusFailed, reasonInvalidParams)
	wantApplied(t, prio("low", "high"), "priority", "low")
}

// MARK: - Comments

func TestACommentIsAnOwnerThreadAndEchoesItsID(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	got := e.board(e.request("board_comment_add", id(tg), map[string]any{"workbench_id": wb, "body": "  Ship it  "}))
	var cid int64
	var author, body string
	if err := e.db.QueryRow(`SELECT id, author, body FROM project_comments WHERE target_id = ?`, tg).Scan(&cid, &author, &body); err != nil {
		t.Fatal(err)
	}
	wantApplied(t, got, "comment_id", cid)
	if author != "owner" || body != "Ship it" {
		t.Fatalf("author %q body %q", author, body)
	}
}

// A board write nudges the board's records (testABoardWriteAsksForTheBoardsRecordsAtOnce).
func TestABoardWriteAsksForTheBoardsRecordsAtOnce(t *testing.T) {
	for _, k := range boardKinds {
		if !slices.Equal(NudgeTable[k], boardSlices) {
			t.Fatalf("%s nudges %v, want %v", k, NudgeTable[k], boardSlices)
		}
	}
}

func TestAnEmptyOrOverlongCommentIsInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	add := func(body string) actions.Outcome {
		return e.board(e.request("board_comment_add", id(tg), map[string]any{"workbench_id": wb, "body": body}))
	}
	for _, body := range []string{" \n\t ", strings.Repeat("a", 4001)} {
		wantOutcome(t, add(body), wire.StatusFailed, reasonInvalidParams)
	}
	if got := add(strings.Repeat("a", 4000)); got.Status != wire.StatusApplied {
		t.Fatalf("at the cap: %+v", got)
	}
	if e.comments(tg) != 1 {
		t.Fatal("one comment")
	}
}

func TestACommentOffThisBoardIsNotOnBoard(t *testing.T) {
	e := newEnv(t)
	wb, _ := e.seedTarget("todo", "medium")
	_, other := e.seedTarget("todo", "medium")
	e.exec(`INSERT INTO targets (text, level, period_start, period_end, status, priority, ownership, source_type)
		VALUES ('Personal', 'day', '2026-10-31', '2026-10-31', 'todo', 'medium', 'mine', 'manual')`)
	noBoard := int64(e.count(`SELECT MAX(id) FROM targets`))
	for _, tg := range []int64{other, noBoard} {
		got := e.board(e.request("board_comment_add", id(tg), map[string]any{"workbench_id": wb, "body": "Hi"}))
		wantOutcome(t, got, wire.StatusFailed, reasonNotOnBoard)
	}
	missing := e.board(e.request("board_comment_add", id(999_999), map[string]any{"workbench_id": wb, "body": "Hi"}))
	wantOutcome(t, missing, wire.StatusFailed, reasonNotFound)
	if e.comments(other) != 0 {
		t.Fatal("nothing written")
	}
}

func (e *env) comment(wb, tg, parent int64, status string) int64 {
	e.t.Helper()
	p := sql.NullInt64{Int64: parent, Valid: parent != 0}
	cid, err := e.db.AddWorkbenchComment(db.WorkbenchComment{
		WorkbenchID: wb, TargetID: sql.NullInt64{Int64: tg, Valid: true}, ParentID: p, Author: "agent", Body: "Note",
	})
	if err != nil {
		e.t.Fatal(err)
	}
	if status != "" {
		e.exec(`UPDATE project_comments SET status = ? WHERE id = ?`, status, cid)
	}
	return cid
}

func TestAReplyToAResolvedRootReopensIt(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	root := e.comment(wb, tg, 0, "resolved")

	got := e.board(e.request("board_comment_reply", id(root), map[string]any{"workbench_id": wb, "body": "One more thing"}))

	reply := int64(e.count(`SELECT id FROM project_comments WHERE parent_id = ?`, root))
	wantApplied(t, got, "comment_id", reply)
	if s := e.scalar(`SELECT status FROM project_comments WHERE id = ?`, root); s != "open" {
		t.Fatalf("root = %s, want open", s)
	}
}

func TestAReplyUnderAReplyOrAnotherBoardsThreadIsRefused(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	otherWB, otherTarget := e.seedTarget("todo", "medium")
	root := e.comment(wb, tg, 0, "")
	child := e.comment(wb, tg, root, "")
	foreign := e.comment(otherWB, otherTarget, 0, "")
	reply := func(to int64) actions.Outcome {
		return e.board(e.request("board_comment_reply", id(to), map[string]any{"workbench_id": wb, "body": "Hi"}))
	}

	wantOutcome(t, reply(child), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, reply(foreign), wire.StatusFailed, reasonNotOnBoard)
	wantOutcome(t, reply(999_999), wire.StatusFailed, reasonNotFound)
	if e.comments(tg) != 2 || e.comments(otherTarget) != 1 {
		t.Fatal("root and its one reply only")
	}
}

// MARK: - Create

// testACreateRunsTheCLIAsTheOwnerAndEchoesTheNewID: Go runs the CLI's writer
// itself, with the owner as actor and the trimmed title and intent.
func TestACreateIsTheOwnersAndEchoesTheNewID(t *testing.T) {
	e := newEnv(t)
	wb, parent := e.seedTarget("todo", "medium")

	got := e.board(e.createAction(wb, "  -Fix the flaky test  ", parent, "--why it matters"))

	newID := int64(e.count(`SELECT MAX(id) FROM targets`))
	wantApplied(t, got, "target_id", newID)
	var title, intent, priority string
	var p int64
	if err := e.db.QueryRow(`SELECT text, intent, priority, parent_id FROM targets WHERE id = ?`, newID).
		Scan(&title, &intent, &priority, &p); err != nil {
		t.Fatal(err)
	}
	// status_actor is cleared by the history trigger, which records it.
	actor := e.scalar(`SELECT actor FROM target_status_history WHERE target_id = ? ORDER BY id LIMIT 1`, newID)
	if title != "-Fix the flaky test" || intent != "--why it matters" || priority != "high" || actor != "owner" || p != parent {
		t.Fatalf("row = %q %q %q %q %d", title, intent, priority, actor, p)
	}
}

func TestACreateWithAParentOfAnotherWorkbenchIsNotOnBoard(t *testing.T) {
	e := newEnv(t)
	wb, _ := e.seedTarget("todo", "medium")
	_, foreign := e.seedTarget("todo", "medium")
	before := e.count(`SELECT COUNT(*) FROM targets`)

	wantOutcome(t, e.board(e.createAction(wb, "Child", foreign, "")), wire.StatusFailed, reasonNotOnBoard)
	if e.count(`SELECT COUNT(*) FROM targets`) != before {
		t.Fatal("nothing created")
	}
}

func TestACreateTitleMustBeOneTo200Characters(t *testing.T) {
	e := newEnv(t)
	wb, _ := e.seedTarget("todo", "medium")
	before := e.count(`SELECT COUNT(*) FROM targets`)

	wantOutcome(t, e.board(e.createAction(wb, " \n ", 0, "")), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, e.board(e.createAction(wb, strings.Repeat("a", 201), 0, "")), wire.StatusFailed, reasonInvalidParams)
	wantOutcome(t, e.board(e.createAction(wb, "Title", 0, strings.Repeat("a", 4001))), wire.StatusFailed, reasonInvalidParams)
	if e.count(`SELECT COUNT(*) FROM targets`) != before {
		t.Fatal("nothing created")
	}
	if got := e.board(e.createAction(wb, strings.Repeat("a", 200), 0, "")); got.Status != wire.StatusApplied {
		t.Fatalf("at the cap: %+v", got)
	}
}

func TestAFailedCreateIsWriteFailed(t *testing.T) {
	e := newEnv(t)
	wb, _ := e.seedTarget("todo", "medium")
	e.exec(`CREATE TRIGGER fail_target_insert BEFORE INSERT ON targets BEGIN SELECT RAISE(ABORT, 'database is locked'); END`)

	got := e.board(e.createAction(wb, "Task", 0, ""))

	wantOutcome(t, got, wire.StatusFailed, reasonWriteFailed)
	if !strings.Contains(got.Message, "database is locked") {
		t.Fatalf("message = %q", got.Message)
	}
}

// The write waits on the database lock: the handler's own timeout answers
// outcome_unknown; the write is never cut and lands once the lock goes.
func TestAHungCreateIsCutByTheHandlersTimeout(t *testing.T) {
	e := newEnv(t)
	wb, _ := e.seedTarget("todo", "medium")
	e.h.d.Timeout = 50 * time.Millisecond
	tx, err := e.db.Begin() // holds the only connection and the write lock
	if err != nil {
		t.Fatal(err)
	}

	got := e.board(e.createAction(wb, "Task", 0, ""))
	_ = tx.Rollback()

	if got.Status != wire.StatusFailed || got.Reason != reasonOutcomeUnknown || got.Message != boardTimeoutMessage {
		t.Fatalf("outcome = %+v", got)
	}
}

func TestEveryKindForADeletedWorkbenchIsNotFound(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	root := e.comment(wb, tg, 0, "")
	e.exec(`DELETE FROM projects WHERE id = ?`, wb)
	for _, req := range []actions.Request{
		e.statusAction(tg, wb, "done", "todo"),
		e.request("board_target_priority", id(tg), map[string]any{"workbench_id": wb, "priority": "high", "from_priority": "medium"}),
		e.request("board_comment_add", id(tg), map[string]any{"workbench_id": wb, "body": "Hi"}),
		e.request("board_comment_reply", id(root), map[string]any{"workbench_id": wb, "body": "Hi"}),
		e.createAction(wb, "Task", 0, ""),
	} {
		got := e.board(req)
		wantOutcome(t, got, wire.StatusFailed, reasonNotFound)
	}
}

func TestMissingBoardParamsAreInvalidParams(t *testing.T) {
	e := newEnv(t)
	wb, tg := e.seedTarget("todo", "medium")
	for _, req := range []actions.Request{
		e.request("board_target_status", nil, map[string]any{"workbench_id": wb, "status": "done", "from_status": "todo"}),
		e.request("board_target_status", id(tg), map[string]any{"status": "done", "from_status": "todo"}),
		e.request("board_comment_add", id(tg), map[string]any{"workbench_id": wb}),
		e.request("board_target_create", nil, map[string]any{"workbench_id": wb, "text": "Task"}),
	} {
		wantOutcome(t, e.board(req), wire.StatusFailed, reasonInvalidParams)
	}
}

// §5.2 rule 1: the comment and create kinds are claimed begun before the
// handler, so a crash between begun and the insert is outcome_unknown and
// never applied twice (the processor's TestCrashMidApplyEchoesOutcomeUnknownOnce).
func TestACrashBetweenBegunAndTheInsertNeverWritesASecondComment(t *testing.T) {
	for _, k := range []string{"board_comment_add", "board_comment_reply", "board_target_create"} {
		if !slices.Contains(actions.NonIdempotentKinds, k) {
			t.Fatalf("%s is not claimed begun", k)
		}
	}
}

// Every board kind is registered (a duplicate registration panics) and a
// comment applied twice by its handler would write twice — so the begun claim
// above is what keeps it once.
func TestTheBoardKindsAreRegistered(t *testing.T) {
	e := newEnv(t)
	for _, k := range boardKinds {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("%s was not registered", k)
				}
			}()
			e.disp.Register(k, func(context.Context, actions.Request) actions.Outcome { return actions.Outcome{} }, actions.KindOptions{})
		}()
	}
}
