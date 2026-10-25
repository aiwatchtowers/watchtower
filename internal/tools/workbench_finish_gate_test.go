package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/reviewai"
	"watchtower/internal/workbenchmethod"
)

// The finish_session gates (spec 2026-10-24-finish-whole-ticket, PROJ-14).

// launchedFor records that the Desktop launched session for target.
func launchedFor(t *testing.T, d *db.DB, session, target int64) {
	t.Helper()
	_, err := d.Exec(`UPDATE terminal_sessions SET target_id = ? WHERE id = ?`, target, session)
	require.NoError(t, err)
}

func setTargetStatus(t *testing.T, d *db.DB, id int64, status string) {
	t.Helper()
	_, err := d.Exec(`UPDATE targets SET status = ? WHERE id = ?`, status, id)
	require.NoError(t, err)
}

// ticketTree seeds a group under workbench wb with four leaves: todo,
// in_review, done and blocked, the first two under a sub-group.
func ticketTree(t *testing.T, d *db.DB, wb int64) (group, todo, inReview int64) {
	t.Helper()
	group = db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "Track")
	sub := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{Int64: group, Valid: true}, "Part B")
	todo = db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{Int64: sub, Valid: true}, "Images")
	inReview = db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{Int64: sub, Valid: true}, "Captions")
	setTargetStatus(t, d, inReview, "in_review")
	done := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{Int64: group, Valid: true}, "Part A")
	setTargetStatus(t, d, done, "done")
	blocked := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{Int64: group, Valid: true}, "Waits on design")
	setTargetStatus(t, d, blocked, "blocked")
	return group, todo, inReview
}

func assertNotFinished(t *testing.T, d *db.DB, session int64, actions int) {
	t.Helper()
	at, _ := finishState(t, d, session)
	assert.Empty(t, at, "a refused finish marks nothing")
	assert.Equal(t, actions, countActions(t, d), "nor writes an audit row")
}

func TestProj14_FinishRefusesOpenLeaves(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	group, todo, inReview := ticketTree(t, fx.d, fx.a)
	launchedFor(t, fx.d, session, group)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))

	// The launch target is the ticket, whatever target_id the call names.
	_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"A done.","target_id":%d,"reason":"r"}`, fx.aTarget))
	msg := refusal(t, err)
	assert.Contains(t, msg, fmt.Sprintf("ticket #%d still has 2 open leaves", group))
	assert.Contains(t, msg, fmt.Sprintf("#%d [todo] Images", todo))
	assert.Contains(t, msg, fmt.Sprintf("#%d [in_review] Captions", inReview))
	assert.NotContains(t, msg, "Part A", "a done leaf is not open")
	assert.NotContains(t, msg, "Waits on design", "a blocked leaf already waits on someone")
	assert.NotContains(t, msg, "Part B", "a group is not a leaf")
	assertNotFinished(t, fx.d, session, 0)

	setTargetStatus(t, fx.d, todo, "done")
	setTargetStatus(t, fx.d, inReview, "dismissed")
	mustApply(t, reg, fx.a, "finish_session", `{"summary":"Whole track done.","reason":"r"}`)
}

// A session started by hand has no launch target: the call's target_id is
// the ticket, and with neither nothing is checked.
func TestProj14_FinishTicketFromTargetIDWhenNotLaunched(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, fx.aTarget))
	assert.Contains(t, refusal(t, err), fmt.Sprintf("ticket #%d still has 1 open leaf ", fx.aTarget))
	mustApply(t, reg, fx.a, "finish_session", `{"summary":"Done.","reason":"r"}`)
}

// repoSession is reviewRepoWorkbench with the session launched in the
// workbench folder, as a session the Desktop starts there is.
func repoSession(t *testing.T) (fx workbenchFixture, wb int64, session int64, reg *Registry) {
	t.Helper()
	fx, wb, session, reg = reviewRepoWorkbench(t)
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET folder_path = ? WHERE id = ?`, reviewFolder(t, fx.d, wb), session)
	require.NoError(t, err)
	return fx, wb, session, reg
}

// linkIntent links n new targets of wb to session: the overview's intent
// items, in order.
func linkIntent(t *testing.T, d *db.DB, wb, session int64, n int) {
	t.Helper()
	for i := 1; i <= n; i++ {
		id := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, fmt.Sprintf("goal %d", i))
		setTargetStatus(t, d, id, "done")
		require.NoError(t, d.LinkSessionTarget(session, id))
	}
}

func TestProj14_HandoverAskPassesBothGates(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	group, todo, _ := ticketTree(t, fx.d, wb)
	launchedFor(t, fx.d, session, group)
	id := askID(t, mustApply(t, reg, wb, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Images later?",`+
		`"questions":[{"question":"Leave images for a new session?","options":[{"label":"Yes"},{"label":"No"}]}],`+
		`"target_id":%d,"reason":"r"}`, todo)))

	out := mustApply(t, reg, wb, "finish_session", fmt.Sprintf(`{"summary":"A done, B asked.","handover_ask_id":%d,"reason":"r"}`, id))
	assert.EqualValues(t, id, out["handover_ask_id"])
	assert.EqualValues(t, 1, out["open_asks"])
	answerAsk(t, fx.d, id, `{"answers":[{"id":"1","labels":["Yes"]}]}`)
	mustApply(t, reg, wb, "finish_session", fmt.Sprintf(`{"summary":"A done, B handed over.","handover_ask_id":%d,"reason":"r"}`, id))
}

func TestProj14_HandoverAskRefusals(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	other := seedTerminalSession(t, fx.d, fx.a)
	group, todo, _ := ticketTree(t, fx.d, fx.a)
	launchedFor(t, fx.d, session, group)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	about := func(title string, target int64) string {
		return fmt.Sprintf(`{"kind":"check","title":%q,"target_id":%d,"checklist":[{"text":"Look"}],"reason":"r"}`, title, target)
	}
	theirs := askID(t, mustApply(t, askRegistry(t, fx.d, strconv.FormatInt(other, 10)), fx.a, "ask_owner", about("Theirs", todo)))
	outside := askID(t, mustApply(t, reg, fx.a, "ask_owner", about("Outside", fx.aTarget)))
	untargeted := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAskTitled("No target")))
	withdrawn := askID(t, mustApply(t, reg, fx.a, "ask_owner", about("Withdrawn", todo)))
	mustApply(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"r"}`, withdrawn))
	theirBoard := askID(t, mustApply(t, askRegistry(t, fx.d, ""), fx.b, "ask_owner", about("Beta", fx.bTarget)))
	actions := countActions(t, fx.d)

	for id, want := range map[int64]string{
		theirs:     fmt.Sprintf("handover_ask_id: ask #%d was not filed by this session", theirs),
		outside:    fmt.Sprintf("handover_ask_id: ask #%d is about #%d, outside this session's ticket #%d", outside, fx.aTarget, group),
		untargeted: fmt.Sprintf("handover_ask_id: ask #%d names no target; file it about #%d or one of its sub-targets", untargeted, group),
		withdrawn:  fmt.Sprintf("handover_ask_id: ask #%d is withdrawn", withdrawn),
		theirBoard: fmt.Sprintf("handover_ask_id: no ask with id %d in this workbench", theirBoard),
	} {
		_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","handover_ask_id":%d,"reason":"r"}`, id))
		assert.Equal(t, want, refusal(t, err))
	}
	assertNotFinished(t, fx.d, session, actions)
}

func TestProj14_FinishCheckOffSkipsGates(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	group, _, _ := ticketTree(t, fx.d, wb)
	launchedFor(t, fx.d, session, group)
	require.NoError(t, fx.d.SetWorkbenchMethodology(wb, db.WorkbenchMethodology{FinishCheck: workbenchmethod.FinishOff}))
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
}

// cacheOverview caches an overview of the session's folder as it stands with
// the given coverage statuses.
func cacheOverview(t *testing.T, d *db.DB, wb, session int64, statuses ...string) {
	t.Helper()
	ctx := context.Background()
	p, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	snap, err := SnapshotReviewSession(ctx, d, p, session)
	require.NoError(t, err)
	in, err := ReviewOverviewInput(ctx, d, p, session)
	require.NoError(t, err)
	var ov reviewai.Overview
	for i, s := range statuses {
		ov.Coverage = append(ov.Coverage, reviewai.Coverage{Index: i + 1, Item: fmt.Sprintf("item %d", i+1), Status: s})
	}
	js, err := json.Marshal(ov)
	require.NoError(t, err)
	require.NoError(t, d.PutReviewOverview(wb, snap.Tree, snap.Base, reviewai.IntentHash(in.Intent, in.Notes), string(js), "m"))
}

func TestProj14_FinishRefusesWithoutOverview(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	finishGateExecutable = func() (string, error) { return "/opt/watch tower/watchtower", nil }
	t.Cleanup(func() { finishGateExecutable = os.Executable })

	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Contains(t, refusal(t, err), fmt.Sprintf("run `'/opt/watch tower/watchtower' workbench review overview --workbench %d --session %d --json`", wb, session))
	assertNotFinished(t, fx.d, session, 0)

	cacheOverview(t, fx.d, wb, session, "done")
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)

	// A change after the overview is a new tree: the overview is asked again.
	require.NoError(t, os.WriteFile(filepath.Join(reviewFolder(t, fx.d, wb), "c.go"), []byte("gamma\n"), 0o600))
	_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Done again.","reason":"r"}`)
	assert.Contains(t, refusal(t, err), "your changes have no AI overview yet")
}

// A new note changes the intent the overview was made for: it is asked again.
func TestProj14_ANoteAfterTheOverviewAsksForItAgain(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	cacheOverview(t, fx.d, wb, session, "done")
	mustApply(t, reg, wb, "annotate_changes", `{"notes":[{"path":"b.go","start_line":1,"end_line":1,"note":"why"}],"reason":"r"}`)
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Contains(t, refusal(t, err), "your changes have no AI overview yet")
}

func TestProj14_FinishRefusesUncoveredItems(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	linkIntent(t, fx.d, wb, session, 4)
	// Item 4 has no coverage entry at all: a pass needs a done for each item.
	cacheOverview(t, fx.d, wb, session, "done", "partial", "not_found")
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	msg := refusal(t, err)
	assert.Contains(t, msg, "2. [partial] item 2")
	assert.Contains(t, msg, "3. [not_found] item 3")
	assert.Contains(t, msg, "4. [missing] goal 4")
	assert.NotContains(t, msg, "item 1")
	assertNotFinished(t, fx.d, session, 0)

	id := askID(t, mustApply(t, reg, wb, "ask_owner", questionAskTitled("Reviewer wrong on 2 and 3?")))
	mustApply(t, reg, wb, "finish_session", fmt.Sprintf(`{"summary":"Done.","handover_ask_id":%d,"reason":"r"}`, id))
}

func TestProj14_AllItemsDonePasses(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	linkIntent(t, fx.d, wb, session, 2)
	cacheOverview(t, fx.d, wb, session, "done", "done")
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
}

// A session launched in, or recorded working in, a worktree of its own and
// now back in the workbench folder: that folder's diff is not its work.
func TestProj14_LeftItsWorktreeSkipsTheOverview(t *testing.T) {
	t.Run("launched in a worktree", func(t *testing.T) {
		fx, wb, session, reg := repoSession(t)
		_, err := fx.d.Exec(`UPDATE terminal_sessions SET folder_path = ? WHERE id = ?`, t.TempDir(), session)
		require.NoError(t, err)
		mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	})
	t.Run("recorded a worktree", func(t *testing.T) {
		fx, wb, session, reg := repoSession(t)
		_, err := fx.d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
			VALUES (?, ?, 'wt/x', '2026-10-24T00:00:00.000Z')`, session, t.TempDir())
		require.NoError(t, err)
		mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	})
	t.Run("recorded only the workbench folder", func(t *testing.T) {
		fx, wb, session, reg := repoSession(t)
		_, err := fx.d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
			VALUES (?, ?, 'main', '2026-10-24T00:00:00.000Z')`, session, reviewFolder(t, fx.d, wb))
		require.NoError(t, err)
		_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
		assert.Contains(t, refusal(t, err), "your changes have no AI overview yet")
	})
}

// A git failure other than "not a repository" refuses; it never passes.
func TestProj14_GitFailureRefuses(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	budget := finishGateBudget
	finishGateBudget = time.Nanosecond
	t.Cleanup(func() { finishGateBudget = budget })
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "finish check: reading the session's changes")
	assertNotFinished(t, fx.d, session, 0)
}

func TestProj14_OpenLeavesRefusalListsAtMostTwenty(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	for i := 0; i < 24; i++ {
		db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, fmt.Sprintf("leaf %d", i))
	}
	// A target of another workbench under the same id range never counts.
	db.SeedTestWorkbenchTarget(t, fx.d, fx.b, sql.NullInt64{Int64: fx.bTarget, Valid: true}, "beta leaf")
	launchedFor(t, fx.d, session, fx.aTarget)
	_, err := proposeIn(t, askRegistry(t, fx.d, strconv.FormatInt(session, 10)), fx.a, "finish_session", `{"summary":"Done.","reason":"r"}`)
	msg := refusal(t, err)
	assert.Contains(t, msg, "still has 24 open leaves")
	assert.Equal(t, 20, strings.Count(msg, "] leaf "))
	assert.Contains(t, msg, "\n… 4 more")
	assert.NotContains(t, msg, "beta leaf")
}

// An empty diff — everything committed and merged — has nothing to review.
func TestProj14_EmptyDiffSkipsTheOverview(t *testing.T) {
	fx, wb, _, reg := repoSession(t)
	dir := reviewFolder(t, fx.d, wb)
	bin, _ := gitbin.Locate()
	for _, args := range [][]string{{"add", "."}, {"commit", "-q", "-m", "b"}} {
		cmd := exec.Command(bin, args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, string(out))
	}
	mustApply(t, reg, wb, "finish_session", `{"summary":"Merged.","reason":"r"}`)
}

func reviewFolder(t *testing.T, d *db.DB, wb int64) string {
	t.Helper()
	p, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	return p.FolderPath
}
