package tools

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The finish gate of an armed session (spec 2026-11-16-watchman-design §3,
// PROJ-14): finish_session queues a review_code item and passes on the
// round's Approve.

// armedRepoSession is repoSession armed, its overview cached (no intent
// items, so the overview gate passes), with a registry counting wakes.
func armedRepoSession(t *testing.T) (fx workbenchFixture, wb, session int64, reg *Registry, wakes *atomic.Int32) {
	t.Helper()
	fx, wb, session, _ = repoSession(t)
	cacheOverview(t, fx.d, wb, session)
	armSession(t, fx.d, session)
	wakes = &atomic.Int32{}
	return fx, wb, session, watchmanRegistry(t, fx.d, session, wakes), wakes
}

// sentRoundAt records a sent round of session at the folder's tree as it
// stands (or at tree when not ""), approved or with changes.
func sentRoundAt(t *testing.T, d *db.DB, wb, session int64, tree string, approve bool) int64 {
	t.Helper()
	if tree == "" {
		p, err := d.GetWorkbench(wb)
		require.NoError(t, err)
		snap, err := SnapshotReviewSession(context.Background(), d, p, session)
		require.NoError(t, err)
		tree = snap.Tree
	}
	id, err := d.CreateReviewRound(db.ReviewRound{ProjectID: wb, SessionID: sql.NullInt64{Int64: session, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "base", BaseLabel: "main", TreeSHA: tree})
	require.NoError(t, err)
	if approve {
		ok, err := d.ApproveReviewRound(wb, id, false)
		require.NoError(t, err)
		require.True(t, ok)
	} else {
		_, ok, err := d.SendReviewRound(wb, id)
		require.NoError(t, err)
		require.True(t, ok)
	}
	return id
}

func TestProj14_FinishArmedQueuesReviewAndRefuses(t *testing.T) {
	fx, wb, session, reg, wakes := armedRepoSession(t)
	group := db.SeedTestWorkbenchTarget(t, fx.d, wb, sql.NullInt64{}, "Ticket")
	setTargetStatus(t, fx.d, group, "done")
	launchedFor(t, fx.d, session, group)

	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"All done, token=abc123SECRETxyz rotated.","reason":"r"}`)
	assert.Equal(t, "Watchman is reviewing this session's changes; keep working on what is left and call finish_session again after its review round arrives",
		refusal(t, err))
	assertNotFinished(t, fx.d, session, 0)
	it, err := fx.d.WatchmanItemByRef("session", session, "review_code")
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, "queued", it.State)
	assert.Equal(t, wb, it.WorkbenchID)
	assert.Equal(t, session, it.SessionID)
	assert.Equal(t, group, it.TargetID)
	assert.Equal(t, "All done, token=[secret] rotated.", it.Question)
	assert.Equal(t, int32(1), wakes.Load())

	// Called again before the round: the item is kept, not queued twice.
	_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	refusal(t, err)
	assert.Equal(t, 1, watchmanItemCount(t, fx.d))
	assert.Equal(t, int32(1), wakes.Load(), "no new item, no wake")

	// A round that asked for changes: the next call queues a review of what
	// followed it.
	round := sentRoundAt(t, fx.d, wb, session, "", false)
	_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Fixed.","reason":"r"}`)
	refusal(t, err)
	next, err := fx.d.WatchmanItemByRef("round", round, "review_code")
	require.NoError(t, err)
	require.NotNil(t, next, "a follow-up review is queued against the last round")
	assert.Equal(t, int32(2), wakes.Load())
}

func TestProj14_FinishArmedPassesOnApprovedRoundAtHead(t *testing.T) {
	fx, wb, session, reg, wakes := armedRepoSession(t)

	// Approved, but at another tree: the changes since are reviewed.
	old := sentRoundAt(t, fx.d, wb, session, "0123456789012345678901234567890123456789", true)
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	refusal(t, err)
	it, err := fx.d.WatchmanItemByRef("round", old, "review_code")
	require.NoError(t, err)
	require.NotNil(t, it)

	sentRoundAt(t, fx.d, wb, session, "", true)
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Equal(t, int32(1), wakes.Load())
}

func TestProj14_FinishArmedPassesWhenReviewParked(t *testing.T) {
	fx, wb, session, reg, _ := armedRepoSession(t)
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	refusal(t, err)
	_, err = fx.d.Exec(`UPDATE watchman_items SET state = 'done', outcome = 'parked', park_reason = 'merging to main is yours'
		WHERE ref_kind = 'session' AND ref_id = ?`, session)
	require.NoError(t, err)
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
}

func TestProj14_FinishUnarmedUnchanged(t *testing.T) {
	fx, wb, session, _ := repoSession(t)
	cacheOverview(t, fx.d, wb, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Zero(t, watchmanItemCount(t, fx.d))
	assert.Zero(t, wakes.Load())

	// The existing gates still refuse first, armed or not.
	fx2, wb2, session2, reg2, _ := armedRepoSession(t)
	linkIntent(t, fx2.d, wb2, session2, 1)
	_, err := proposeIn(t, reg2, wb2, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Contains(t, refusal(t, err), "your changes have no AI overview yet")
	assert.Zero(t, watchmanItemCount(t, fx2.d), "nothing queued before the existing gates pass")
}

// A handover ask of an armed session becomes the twin's handover item. The
// workbench folder is not a repository: no diff, so the review gate passes.
func TestFinishSession_ArmedHandoverMarksItem(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Images later?",`+
		`"questions":[{"question":"Leave images for a new session?","options":[{"label":"Yes"},{"label":"No"}]}],`+
		`"target_id":%d,"reason":"r"}`, fx.aTarget)))

	out := mustApply(t, reg, fx.a, "finish_session",
		fmt.Sprintf(`{"summary":"A done.","target_id":%d,"handover_ask_id":%d,"reason":"r"}`, fx.aTarget, id))
	assert.EqualValues(t, id, out["handover_ask_id"])
	it, err := fx.d.WatchmanItemByRef("ask", id, "handover")
	require.NoError(t, err)
	require.NotNil(t, it, "the ask's item is now a handover")
	asAsk, err := fx.d.WatchmanItemByRef("ask", id, "ask")
	require.NoError(t, err)
	assert.Nil(t, asAsk)
	assert.Equal(t, 1, watchmanItemCount(t, fx.d))
}

// Only a parked review item passes on its own: one the owner answered first
// (or any other done outcome) waits for a round approved at the tree.
func TestProj14_FinishArmedDoneNotParkedRefuses(t *testing.T) {
	fx, wb, session, reg, _ := armedRepoSession(t)
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	refusal(t, err)
	_, err = fx.d.Exec(`UPDATE watchman_items SET state = 'done', outcome = 'owner_first' WHERE ref_kind = 'session' AND ref_id = ?`, session)
	require.NoError(t, err)
	_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	msg := refusal(t, err)
	assert.NotEqual(t, watchmanReviewingRefusal, msg, "nothing is reviewing: the agent must not just wait")
	assert.Equal(t, "Watchman's review of this session's changes ended without an approval (owner_first); "+
		"the owner will look at it in the morning journal. finish_session stays blocked until a review round of these "+
		"changes is approved — continue with other work", msg)
	assert.NotContains(t, msg, "ask_owner", "an ask does not send a review round")
	assertNotFinished(t, fx.d, session, 0)
}

// A review-gate read that fails refuses with a retryable error, like the
// other gates; nothing is finished.
func TestProj14_FinishArmedReadFailureRefuses(t *testing.T) {
	fx, wb, session, reg, _ := armedRepoSession(t)
	_, err := fx.d.Exec(`ALTER TABLE watchman_items RENAME TO watchman_items_gone`)
	require.NoError(t, err)
	_, err = proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "call finish_session again")
	assertNotFinished(t, fx.d, session, 0)
}

// A finish the review gate refuses still makes the ask its handover, held
// (final review B-I1): the twin neither decides it as a question nor
// continues a session that has not finished. A finish that passes once the
// review approves releases it.
func TestFinishSession_RefusedFinishHoldsTheHandover(t *testing.T) {
	fx, wb, session, reg, wakes := armedRepoSession(t)
	id := askID(t, mustApply(t, reg, wb, "ask_owner", `{"kind":"question","title":"Images later?",`+
		`"questions":[{"question":"Leave images?","options":[{"label":"Yes"},{"label":"No"}]}],"reason":"r"}`))
	asked := wakes.Load()
	finish := fmt.Sprintf(`{"summary":"A done.","handover_ask_id":%d,"reason":"r"}`, id)
	_, err := proposeIn(t, reg, wb, "finish_session", finish)
	assert.Equal(t, watchmanReviewingRefusal, refusal(t, err))
	it, err := fx.d.WatchmanItemByRef("ask", id, "handover")
	require.NoError(t, err)
	require.NotNil(t, it, "the ask is the handover already")
	assert.Equal(t, "queued", it.State)
	assert.Equal(t, db.WatchmanHandoverHeld, it.Error, "held while the finish is refused")
	asAsk, err := fx.d.WatchmanItemByRef("ask", id, "ask")
	require.NoError(t, err)
	assert.Nil(t, asAsk, "no ordinary ask left to decide as a question")
	assert.Equal(t, asked+1, wakes.Load(), "the review item's wake only")

	// Refused again: still held, still one handover row.
	_, err = proposeIn(t, reg, wb, "finish_session", finish)
	refusal(t, err)
	it, err = fx.d.WatchmanItemByRef("ask", id, "handover")
	require.NoError(t, err)
	assert.Equal(t, db.WatchmanHandoverHeld, it.Error)

	sentRoundAt(t, fx.d, wb, session, "", true)
	mustApply(t, reg, wb, "finish_session", finish)
	it, err = fx.d.WatchmanItemByRef("ask", id, "handover")
	require.NoError(t, err)
	assert.Equal(t, "queued", it.State)
	assert.Empty(t, it.Error, "released once the finish passed")
	assert.Equal(t, asked+2, wakes.Load(), "the release wakes the twin")
}

// In a session handed to Watchman a review ask is the owner's verdict on a
// document, never a handover (final review B-minor 1).
func TestFinishSession_ReviewAskIsNoHandover(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec.md", "# Spec\n")
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", `{"kind":"review","title":"Review","doc_path":"docs/spec.md","reason":"r"}`))
	actions := countActions(t, fx.d)
	_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","handover_ask_id":%d,"reason":"r"}`, id))
	assert.Equal(t, fmt.Sprintf("handover_ask_id: ask #%d is a review; file a question or check ask that says what is left and why", id),
		refusal(t, err))
	assertNotFinished(t, fx.d, session, actions)
}

// The ask's own insert failed: the finish queues it directly as a handover.
func TestFinishSession_ArmedHandoverQueuedAfterFailedInsert(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	captureWatchmanLog(t)
	_, err := fx.d.Exec(`CREATE TRIGGER wm_fail BEFORE INSERT ON watchman_items BEGIN SELECT RAISE(ABORT, 'database is locked'); END`)
	require.NoError(t, err)
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Images later?",`+
		`"questions":[{"question":"Leave images?","options":[{"label":"Yes"},{"label":"No"}]}],"target_id":%d,"reason":"r"}`, fx.aTarget)))
	require.Zero(t, watchmanItemCount(t, fx.d))
	_, err = fx.d.Exec(`DROP TRIGGER wm_fail`)
	require.NoError(t, err)

	mustApply(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"A done.","target_id":%d,"handover_ask_id":%d,"reason":"r"}`, fx.aTarget, id))
	it, err := fx.d.WatchmanItemByRef("ask", id, "handover")
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, "queued", it.State)
	assert.Equal(t, fx.aTarget, it.TargetID)
	assert.Equal(t, "Images later?", it.Question)
	assert.Equal(t, 1, watchmanItemCount(t, fx.d))
	assert.Equal(t, int32(1), wakes.Load())
}

// A handover ask that is no longer open is not queued by the fallback.
func TestFinishSession_ArmedHandoverOfAnsweredAskQueuesNothing(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	captureWatchmanLog(t)
	_, err := fx.d.Exec(`CREATE TRIGGER wm_fail BEFORE INSERT ON watchman_items BEGIN SELECT RAISE(ABORT, 'database is locked'); END`)
	require.NoError(t, err)
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Images later?",`+
		`"questions":[{"question":"Leave images?","options":[{"label":"Yes"},{"label":"No"}]}],"target_id":%d,"reason":"r"}`, fx.aTarget)))
	_, err = fx.d.Exec(`DROP TRIGGER wm_fail`)
	require.NoError(t, err)
	answerAsk(t, fx.d, id, `{"answers":[{"id":"1","labels":["Yes"]}]}`)

	mustApply(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"A done.","target_id":%d,"handover_ask_id":%d,"reason":"r"}`, fx.aTarget, id))
	assert.Zero(t, watchmanItemCount(t, fx.d))
	assert.Zero(t, wakes.Load())
}

// Unarmed, the finish contract is unchanged: a review ask still passes as
// the handover ask (fix wave 2).
func TestFinishSession_UnarmedReviewAskStillHandsOver(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec.md", "# Spec\n")
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", `{"kind":"review","title":"Review","doc_path":"docs/spec.md","reason":"r"}`))
	out := mustApply(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","handover_ask_id":%d,"reason":"r"}`, id))
	assert.EqualValues(t, id, out["handover_ask_id"])
}
