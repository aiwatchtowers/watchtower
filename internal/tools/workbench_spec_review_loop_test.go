package tools

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

const loopSpecPath = "docs/superpowers/specs/a-design.md"

// openItemsJSON is a finished round's open items: one agreement ag:1 and one
// blind spot bs:1.
const openItemsJSON = `[{"key":"ag:1","kind":"agreement","text":"Store in SQLite","note":"missing","round":1},` +
	`{"key":"bs:1","kind":"blind_spot","text":"No migration","note":"why","round":1}]`

// loopFixture is a workbench with a terminal session the ask tools see and a
// spec document to review.
type loopFixture struct {
	workbenchFixture
	reg *Registry
}

func newLoopFixture(t *testing.T, launch SpecReviewLauncher) loopFixture {
	t.Helper()
	fx := newWorkbenchFixture(t)
	sid := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistryWith(t, fx.d, strconv.FormatInt(sid, 10), launch)
	writeWorkbenchFile(t, fx.d, fx.a, loopSpecPath, "# Spec\n")
	return loopFixture{workbenchFixture: fx, reg: reg}
}

func okLauncher(int64) error { return nil }

// finishRound marks askID's queued row done with openItemsJSON, as the
// reviewer would for a round that leaves work for the author.
func finishRound(t *testing.T, d *db.DB, askID int64) {
	t.Helper()
	_, err := d.Exec(`UPDATE spec_reviews SET status = 'done', open_items = ?, finished_at = '2026-10-26T10:00:00Z'
		WHERE ask_id = ?`, openItemsJSON, askID)
	require.NoError(t, err)
}

func reRound(prev int64, replies string) string {
	return fmt.Sprintf(`{"kind":"review","title":"Review","doc_path":%q,"previous_ask_id":%d,"changes":"fixed",`+
		`"review_replies":%s,"reason":"r"}`, loopSpecPath, prev, replies)
}

func specRow(t *testing.T, d *db.DB, askID int64) *db.SpecReview {
	t.Helper()
	r, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	return r
}

func TestAskOwner_SessionBoundSpecStartsLoop(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	out := mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath))
	id := askID(t, out)

	assert.Equal(t, "author_loop", out["spec_review"])
	r := specRow(t, fx.d, id)
	assert.Equal(t, "author", r.Loop)
	assert.Equal(t, 1, r.Round)
	assert.Equal(t, "queued", r.Status)
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, id).Status)
}

func TestAskOwner_NoSessionNoLoop(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistryWith(t, fx.d, "", okLauncher)
	writeWorkbenchFile(t, fx.d, fx.a, loopSpecPath, "# Spec\n")
	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath))

	assert.Equal(t, "queued", out["spec_review"])
	assert.Equal(t, "", specRow(t, fx.d, askID(t, out)).Loop)
}

// SPECREVIEW-02 in the loop: a reviewer that does not start shows the ask to
// the owner at once.
func TestAskOwner_LoopSkipReveals(t *testing.T) {
	fx := newLoopFixture(t, func(int64) error { return ErrSpecReviewSkipped{Reason: "plan near limit"} })
	out := mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath))
	id := askID(t, out)

	assert.Equal(t, "skipped: plan near limit", out["spec_review"])
	r := specRow(t, fx.d, id)
	assert.Equal(t, "skipped", r.Status)
	assert.Equal(t, "owner", r.Loop)
	assert.Equal(t, specreview.EndReviewerFailed, r.LoopEnd)
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, id).Status)
}

func TestAskOwner_RoundTwoLaunchFailureRevealsWithLedger(t *testing.T) {
	fail := false
	fx := newLoopFixture(t, func(int64) error {
		if fail {
			return fmt.Errorf("no exec")
		}
		return nil
	})
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)
	fail = true

	out := mustApply(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"disagree","note":"SQLite is wrong here"}]`))
	id := askID(t, out)

	assert.Equal(t, "skipped: launch failed: no exec", out["spec_review"])
	r := specRow(t, fx.d, id)
	assert.Equal(t, "owner", r.Loop)
	assert.Equal(t, specreview.EndReviewerFailed, r.LoopEnd)
	var ledger []specreview.LedgerEntry
	require.NoError(t, json.Unmarshal([]byte(r.Ledger), &ledger))
	require.Len(t, ledger, 2)
	assert.Equal(t, "SQLite is wrong here", ledger[0].VerdictNote)
}

func TestAskOwner_RepliesNeedLoopingPrevious(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	// No previous_ask_id at all.
	_, err := proposeIn(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"review","title":"Review","doc_path":%q,`+
		`"review_replies":[{"key":"ag:1","reply":"fixed"}],"reason":"r"}`, loopSpecPath))
	assert.Contains(t, refusal(t, err), "review_replies")

	// A previous ask without a loop review.
	noLoop := askRegistryWith(t, fx.d, "", okLauncher)
	prev := askID(t, mustApply(t, noLoop, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	_, err = proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(prev, `[{"key":"ag:1","reply":"fixed"}]`))
	assert.Contains(t, refusal(t, err), "not a spec review in the author loop")
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, prev).Status, "the refused ask supersedes nothing")
}

func TestAskOwner_RepliesRefusedAfterReveal(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)
	_, err := fx.d.RevealSpecLoop(first, specreview.EndTimeout, "", time.Now())
	require.NoError(t, err)

	_, err = proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"fixed"}]`))
	assert.Contains(t, refusal(t, err), "the owner has this review now — wait for their answer")
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, first).Status)
}

func TestAskOwner_RepliesUnknownKeyRefused(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)

	_, err := proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:9","reply":"fixed"}]`))
	assert.Contains(t, refusal(t, err), "ag:9 is not a finding")
	_, err = proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"maybe"}]`))
	assert.Contains(t, refusal(t, err), "fixed or disagree")
}

func TestAskOwner_DisagreeNeedsNote(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)

	_, err := proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"disagree","note":"  "}]`))
	assert.Contains(t, refusal(t, err), "disagree needs a note")
	long := strings.Repeat("я", maxReplyNoteRunes+1)
	_, err = proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"fixed","note":"`+long+`"}]`))
	assert.Contains(t, refusal(t, err), "longer than 500")
	ok := strings.Repeat("я", maxReplyNoteRunes)
	mustApply(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"disagree","note":"`+ok+`"}]`))
}

func TestAskOwner_RoundTwoQueuedWithReplies(t *testing.T) {
	var launched []int64
	fx := newLoopFixture(t, func(id int64) error { launched = append(launched, id); return nil })
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)

	out := mustApply(t, fx.reg, fx.a, "ask_owner", reRound(first,
		`[{"key":"ag:1","reply":"fixed","note":" added it "},{"key":"bs:1","reply":"disagree","note":"out of scope"}]`))
	id := askID(t, out)

	assert.Equal(t, "author_loop", out["spec_review"])
	assert.Equal(t, float64(first), out["superseded"])
	assert.Equal(t, []int64{first, id}, launched)
	r := specRow(t, fx.d, id)
	assert.Equal(t, "author", r.Loop)
	assert.Equal(t, 2, r.Round)
	var replies []specreview.Reply
	require.NoError(t, json.Unmarshal([]byte(r.Replies), &replies))
	assert.Equal(t, []specreview.Reply{
		{Key: "ag:1", Reply: "fixed", Note: "added it"},
		{Key: "bs:1", Reply: "disagree", Note: "out of scope"},
	}, replies)

	// Without replies a hidden previous ask still advances the round.
	finishRound(t, fx.d, id)
	third := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", reRound(id, `[]`)))
	r3 := specRow(t, fx.d, third)
	assert.Equal(t, 3, r3.Round)
	assert.Equal(t, "", r3.Replies)
}

// A round past MaxLoopRounds starts no hidden loop: the ask is a classic
// visible review.
func TestAskOwner_RoundPastCapStartsNoLoop(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)
	_, err := fx.d.Exec(`UPDATE spec_reviews SET round = ? WHERE ask_id = ?`, specreview.MaxLoopRounds, first)
	require.NoError(t, err)

	out := mustApply(t, fx.reg, fx.a, "ask_owner", reRound(first, `[]`))
	id := askID(t, out)

	assert.Equal(t, "queued", out["spec_review"])
	assert.Equal(t, "", specRow(t, fx.d, id).Loop)
}

// review_replies on an ask that will not loop (no session, no reviewer on the
// surface, or not a spec/plan) are refused instead of dropped.
func TestAskOwner_RepliesRefusedWhenAskWillNotLoop(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)
	replies := `[{"key":"ag:1","reply":"fixed"}]`
	refused := func(reg *Registry, args, why string) {
		t.Helper()
		rc, err := proposeIn(t, reg, fx.a, "ask_owner", args)
		require.NoError(t, err, why)
		assert.Equal(t, "failed", rc.Status, why)
		assert.Equal(t, errRepliesNoLoop, rc.Error, why)
	}

	refused(askRegistryWith(t, fx.d, "", okLauncher), reRound(first, replies), "no session")
	sid := seedTerminalSession(t, fx.d, fx.a)
	refused(askRegistryWith(t, fx.d, strconv.FormatInt(sid, 10), nil), reRound(first, replies), "no reviewer on this surface")
	refused(fx.reg, fmt.Sprintf(`{"kind":"review","title":"Review","doc_path":%q,"doc_type":"other",`+
		`"previous_ask_id":%d,"changes":"fixed","review_replies":%s,"reason":"r"}`, loopSpecPath, first, replies), "doc_type other")

	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, first).Status, "the refused asks supersede nothing")
}

// A previous review the owner already has (loop 'owner') starts no new hidden
// loop: the re-round is a classic visible review.
func TestAskOwner_OwnerLoopPreviousStartsClassicReview(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	finishRound(t, fx.d, first)
	_, err := fx.d.RevealSpecLoop(first, specreview.EndSettled, "", time.Now())
	require.NoError(t, err)

	out := mustApply(t, fx.reg, fx.a, "ask_owner", reRound(first, `[]`))
	id := askID(t, out)

	assert.Equal(t, "queued", out["spec_review"])
	assert.Equal(t, "", specRow(t, fx.d, id).Loop, "visible to the owner from the start")
}

func TestGetSpecReview_ItemsOnlyForAuthorDone(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	id := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	args := fmt.Sprintf(`{"ask_id":%d}`, id)

	var v map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "get_spec_review", args)), &v))
	assert.Equal(t, []any{}, v["items"])
	assert.Equal(t, "author", v["loop"])
	assert.Equal(t, "queued", v["status"])
	assert.Equal(t, float64(1), v["round"])
	assert.Equal(t, float64(specreview.MaxLoopRounds), v["max_rounds"])
	assert.Contains(t, v["hint"], "wait for the findings line")

	finishRound(t, fx.d, id)
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "get_spec_review", args)), &v))
	items, ok := v["items"].([]any)
	require.True(t, ok)
	require.Len(t, items, 2)
	assert.Equal(t, "ag:1", items[0].(map[string]any)["key"])
	assert.Contains(t, v["hint"], "review_replies")

	_, err := fx.d.RevealSpecLoop(id, specreview.EndTimeout, "", time.Now())
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "get_spec_review", args)), &v))
	assert.Equal(t, []any{}, v["items"])
	assert.Equal(t, "owner", v["loop"])

	// Another workbench's ask and an ask without a review are refused.
	_, err = fx.reg.CallRead(t.Context(), "get_spec_review", json.RawMessage(args), directBinding(fx.b))
	assert.Contains(t, refusal(t, err), "no ask with id")
	q := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", questionAsk))
	_, err = fx.reg.CallRead(t.Context(), "get_spec_review", json.RawMessage(fmt.Sprintf(`{"ask_id":%d}`, q)), directBinding(fx.a))
	assert.Contains(t, refusal(t, err), "has no spec review")
}

func TestGetAsk_SpecLoopKey(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	id := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	q := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", questionAsk))

	var v map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, id))), &v))
	assert.Equal(t, "author", v["spec_loop"])
	var qv map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, q))), &qv))
	assert.NotContains(t, qv, "spec_loop")

	_, err := fx.d.RevealSpecLoop(id, specreview.EndTimeout, "", time.Now())
	require.NoError(t, err)
	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, fx.reg, fx.a, "list_asks", `{"status":"all"}`)), &rows))
	byID := map[float64]map[string]any{}
	for _, r := range rows {
		byID[r["ask_id"].(float64)] = r
	}
	assert.Equal(t, "owner", byID[float64(id)]["spec_loop"])
	assert.NotContains(t, byID[float64(q)], "spec_loop")
}

// A plan is reviewed only after the owner answered the session's spec: an
// open spec ask (hidden in its loop or not) refuses the plan.
func TestAskOwner_PlanWaitsForTheSpec(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	const planPath = "docs/superpowers/plans/a.md"
	writeWorkbenchFile(t, fx.d, fx.a, planPath, "# Plan\n")
	spec := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))

	_, err := proposeIn(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, planPath))
	assert.Contains(t, refusal(t, err), fmt.Sprintf("the spec in ask #%d is not answered yet", spec))

	_, err = fx.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{}', answered_at = '2026-10-27T10:00:00Z' WHERE id = ?`, spec)
	require.NoError(t, err)
	out := mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, planPath))
	assert.Equal(t, "author_loop", out["spec_review"])

	// Another session's open spec does not hold this plan back.
	other := askRegistryWith(t, fx.d, "", okLauncher)
	mustApply(t, other, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath))
	mustApply(t, fx.reg, fx.a, "ask_owner", `{"kind":"review","title":"Plan 2","doc_path":"docs/superpowers/plans/a.md","reason":"r"}`)
}

// After Show Now turned round 1 into a plain review, the author's next
// version is a visible review, not a new hidden loop; replies are refused.
func TestAskOwner_ReRoundAfterShowNowIsVisible(t *testing.T) {
	fx := newLoopFixture(t, okLauncher)
	first := askID(t, mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(specReviewAsk, loopSpecPath)))
	ok, err := fx.d.LeaveSpecLoop(first, specreview.EndOwner)
	require.NoError(t, err)
	require.True(t, ok)

	_, err = proposeIn(t, fx.reg, fx.a, "ask_owner", reRound(first, `[{"key":"ag:1","reply":"fixed"}]`))
	assert.Contains(t, refusal(t, err), "the owner has this review now")

	out := mustApply(t, fx.reg, fx.a, "ask_owner", fmt.Sprintf(
		`{"kind":"review","title":"Review","doc_path":%q,"previous_ask_id":%d,"changes":"v2","reason":"r"}`, loopSpecPath, first))
	assert.Equal(t, "", specRow(t, fx.d, askID(t, out)).Loop)
}
