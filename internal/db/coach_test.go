package db

import (
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func coachFixture(fp string) CoachProposal {
	return CoachProposal{
		Fingerprint: fp, Kind: "add", Destination: "session", PromptID: "",
		Title: "Run the linter first", Why: "three corrections", Metric: "corrections",
		BeforeText: "a", AfterText: "a\nb", Sources: 3,
		Evidence: []CoachEvidence{{Kind: "ask", Ref: "7"}, {Kind: "session", Ref: "s1"}},
	}
}

func TestCoachProposal_RoundTrip(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	p := coachFixture("fp1")
	p.WorkbenchID = wb
	id, err := d.InsertCoachProposal(p, now)
	require.NoError(t, err)
	require.NotZero(t, id)

	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, p.Evidence, got.Evidence)
	assert.Equal(t, wb, got.WorkbenchID)
	assert.Equal(t, "open", got.Status)
	assert.True(t, got.CreatedAt.Equal(now))
	assert.True(t, got.DecidedAt.IsZero())
	assert.Nil(t, got.Baseline)
	assert.Equal(t, int64(0), got.RevertsID)

	global, err := d.InsertCoachProposal(coachFixture("fp2"), now.Add(time.Minute))
	require.NoError(t, err)
	list, err := d.ListCoachProposals()
	require.NoError(t, err)
	require.Len(t, list, 2)
	assert.Equal(t, global, list[0].ID, "newest first")
	assert.Equal(t, int64(0), list[0].WorkbenchID)

	n, err := d.CountOpenCoachProposals()
	require.NoError(t, err)
	assert.Equal(t, 2, n)

	base := 2.5
	require.NoError(t, d.MarkCoachAccepted(id, "after edited", &base, 4, now.Add(time.Hour)))
	acc, err := d.ListCoachProposals("accepted")
	require.NoError(t, err)
	require.Len(t, acc, 1)
	require.NotNil(t, acc[0].Baseline)
	assert.Equal(t, 2.5, *acc[0].Baseline)
	assert.Equal(t, 4, acc[0].BaselineN)
	assert.Equal(t, "after edited", acc[0].AfterText)
	assert.Error(t, d.MarkCoachAccepted(id, "x", nil, 1, now), "only from open")

	v := 1.0
	require.NoError(t, d.SetCoachVerdict(id, "works", &v, now.Add(2*time.Hour)))
	got, err = d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "works", got.Verdict)
	require.NotNil(t, got.VerdictValue)
	assert.Equal(t, 1.0, *got.VerdictValue)

	// Only an accepted proposal takes a verdict.
	assert.ErrorIs(t, d.SetCoachVerdict(global, "works", &v, now), ErrCoachStateChanged)

	fps, err := d.CoachFingerprints()
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"fp1": "accepted", "fp2": "open"}, fps)

	_, err = d.GetCoachProposal(9999)
	assert.ErrorIs(t, err, sql.ErrNoRows)

	require.NoError(t, d.DecideCoachProposal(id, "accepted", "rolled_back", now))
	assert.ErrorIs(t, d.SetCoachVerdict(id, "no_effect", nil, now), ErrCoachStateChanged)
}

func TestInsertCoachProposal_DuplicateFingerprintIsNoop(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	id, err := d.InsertCoachProposal(coachFixture("dup"), now)
	require.NoError(t, err)
	other := coachFixture("dup")
	other.Title = "changed"
	again, err := d.InsertCoachProposal(other, now)
	require.NoError(t, err)
	assert.Zero(t, again)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "Run the linter first", got.Title)
}

func TestDecideCoachProposal_CAS(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	id, err := d.InsertCoachProposal(coachFixture("cas"), now)
	require.NoError(t, err)
	require.NoError(t, d.DecideCoachProposal(id, "open", "declined", now))
	assert.ErrorIs(t, d.DecideCoachProposal(id, "open", "accepted", now), ErrCoachStateChanged)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "declined", got.Status)
	assert.True(t, got.DecidedAt.Equal(now))
}

func TestPromptAdditions_OrderAndDelete(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	p1, err := d.InsertCoachProposal(coachFixture("a1"), now)
	require.NoError(t, err)
	p2, err := d.InsertCoachProposal(coachFixture("a2"), now)
	require.NoError(t, err)
	_, err = d.AddPromptAddition("briefing", "first", p1, now)
	require.NoError(t, err)
	_, err = d.AddPromptAddition("briefing", "second", p2, now.Add(time.Minute))
	require.NoError(t, err)
	_, err = d.AddPromptAddition("other", "x", p2, now)
	require.NoError(t, err)

	got, err := d.ListPromptAdditions("briefing")
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "first", got[0].Text)
	assert.Equal(t, p2, got[1].ProposalID)
	assert.True(t, got[1].CreatedAt.Equal(now.Add(time.Minute)))

	require.NoError(t, d.DeletePromptAdditionsOf(p1))
	got, err = d.ListPromptAdditions("briefing")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "second", got[0].Text)
}

func TestEditPromptAdditions_OneTransaction(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	p1, err := d.InsertCoachProposal(coachFixture("e1"), now)
	require.NoError(t, err)
	keep, err := d.AddPromptAddition("briefing", "keep", 0, now)
	require.NoError(t, err)
	drop, err := d.AddPromptAddition("briefing", "drop", p1, now)
	require.NoError(t, err)
	other, err := d.AddPromptAddition("other", "x", 0, now)
	require.NoError(t, err)

	added, err := d.EditPromptAdditions("briefing", []int64{drop}, []PromptAddition{{Text: "new", ProposalID: p1}}, now)
	require.NoError(t, err)
	require.Len(t, added, 1)
	got, err := d.ListPromptAdditions("briefing")
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, keep, got[0].ID)
	assert.Equal(t, "new", got[1].Text)
	assert.Equal(t, p1, got[1].ProposalID)

	// A row of another prompt refuses the whole edit: nothing is added.
	_, err = d.EditPromptAdditions("briefing", []int64{other}, []PromptAddition{{Text: "never"}}, now)
	require.ErrorIs(t, err, ErrCoachStateChanged)
	got, err = d.ListPromptAdditions("briefing")
	require.NoError(t, err)
	assert.Len(t, got, 2)
}

func TestFirstRoundSpecFindings_SkipsFollowUpsAndUncounted(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	finish := func(askID int64, findings int, at time.Time) {
		queueSpecReview(t, d, askID, at)
		ok, err := d.ClaimSpecReview(askID, 1, at)
		require.NoError(t, err)
		require.True(t, ok)
		require.NoError(t, d.FinishSpecReview(askID, 1, SpecReview{Result: "{}", Findings: findings}, at))
	}
	first := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "review", Title: "s", DocPath: "a.md", DocType: "spec"})
	finish(first, 4, now)
	follow := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "review", Title: "s2", DocPath: "a.md", DocType: "spec",
		PreviousAskID: sql.NullInt64{Int64: first, Valid: true}})
	finish(follow, 9, now)
	uncounted := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "review", Title: "s3", DocPath: "b.md", DocType: "spec"})
	finish(uncounted, -1, now)

	sum, n, err := d.FirstRoundSpecFindings(0, now.Add(-time.Hour), now.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 4, sum)
	assert.Equal(t, 1, n)
	sum, n, err = d.FirstRoundSpecFindings(pid, now.Add(-time.Hour), now.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 4, sum)
	assert.Equal(t, 1, n)
	_, n, err = d.FirstRoundSpecFindings(pid+1000, now.Add(-time.Hour), now.Add(time.Hour))
	require.NoError(t, err)
	assert.Zero(t, n)
	_, n, err = d.FirstRoundSpecFindings(0, now.Add(time.Hour), now.Add(2*time.Hour))
	require.NoError(t, err)
	assert.Zero(t, n, "outside the range")
}

func TestFirstRoundReviewComments_SkipsFollowUpsAndCarried(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	stamp := now.Format(time.RFC3339)
	round := func(prev any) int64 {
		res, err := d.Exec(`INSERT INTO review_rounds (project_id, folder_root, base_sha, tree_sha, prev_round_id, created_at)
			VALUES (?, '/f', 'b', 't', ?, ?)`, pid, prev, stamp)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	comment := func(roundID int64, carried any, status string) {
		_, err := d.Exec(`INSERT INTO review_comments (round_id, body, carried_from, status) VALUES (?, 'c', ?, ?)`,
			roundID, carried, status)
		require.NoError(t, err)
	}
	r1 := round(nil)
	comment(r1, nil, "sent")
	comment(r1, nil, "resolved")
	comment(r1, nil, "draft")    // never sent: not counted
	comment(r1, nil, "outdated") // not counted, as in the signals
	r2 := round(r1)
	var c1 int64
	require.NoError(t, d.QueryRow(`SELECT MIN(id) FROM review_comments`).Scan(&c1))
	comment(r2, c1, "sent")
	comment(r2, nil, "sent")

	sum, rounds, err := d.FirstRoundReviewComments(pid, now.Add(-time.Hour), now.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 2, sum)
	assert.Equal(t, 1, rounds)
	sum, rounds, err = d.FirstRoundReviewComments(0, now.Add(time.Hour), now.Add(2*time.Hour))
	require.NoError(t, err)
	assert.Zero(t, sum+rounds)
}

func TestFinishSpecReview_StoresFindings(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	queueSpecReview(t, d, askID, now)
	got, err := d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, -1, got.Findings, "not counted by default")
	_, err = d.ClaimSpecReview(askID, 7, now)
	require.NoError(t, err)
	require.NoError(t, d.FinishSpecReview(askID, 7, SpecReview{Result: "{}", Findings: 5}, now))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.Equal(t, 5, got.Findings)

	// A --force re-run (or a sweep relaunch) replaces result but keeps the
	// count of the review as it first finished: the coach's first-round number.
	later := now.Add(time.Hour)
	require.NoError(t, d.RequeueSpecReview(askID, true, later))
	ok, err := d.ClaimSpecReview(askID, 8, later)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.FinishSpecReview(askID, 8, SpecReview{Result: `{"x":1}`, Findings: 1}, later))
	got, err = d.GetSpecReview(askID)
	require.NoError(t, err)
	assert.JSONEq(t, `{"x":1}`, got.Result, "the re-run's result is stored")
	assert.Equal(t, 5, got.Findings, "findings are written once")
}

func newTuningConversation(t *testing.T, d *DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, created_at, updated_at)
		VALUES ('', 'analytics_tuning', 0, 0)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func chatSkillFixture(fp, skill string) CoachProposal {
	p := coachFixture(fp)
	p.Destination = "claude_skill_user"
	p.Skill = skill
	return p
}

func TestCoachProposal_NewColumnsRoundTrip(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	conv := newTuningConversation(t, d)
	p := chatSkillFixture("fp-chat", "review-pr")
	p.Origin = "chat"
	p.ConversationID = &conv
	id, err := d.InsertCoachProposal(p, now)
	require.NoError(t, err)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "chat", got.Origin)
	assert.Equal(t, "review-pr", got.Skill)
	require.NotNil(t, got.ConversationID)
	assert.Equal(t, conv, *got.ConversationID)

	weekly, err := d.InsertCoachProposal(coachFixture("fp-weekly"), now)
	require.NoError(t, err)
	got, err = d.GetCoachProposal(weekly)
	require.NoError(t, err)
	assert.Equal(t, "weekly", got.Origin, "an empty origin is written as weekly")
	assert.Equal(t, "", got.Skill)
	assert.Nil(t, got.ConversationID)
}

func TestInsertChatCoachProposal_SetsConversation(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	conv := newTuningConversation(t, d)
	id, err := d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), &conv, now)
	require.NoError(t, err)
	require.NotZero(t, id)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "chat", got.Origin)
	require.NotNil(t, got.ConversationID)
	assert.Equal(t, conv, *got.ConversationID)
	assert.True(t, got.CreatedAt.Equal(now))

	byFP, err := d.CoachProposalByFingerprint("fp1")
	require.NoError(t, err)
	assert.Equal(t, id, byFP.ID)
	_, err = d.CoachProposalByFingerprint("missing")
	assert.ErrorIs(t, err, sql.ErrNoRows)
}

func TestInsertChatCoachProposal_ConversationRemoved(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	conv := newTuningConversation(t, d)
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	id, err := d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), &conv, now)
	assert.True(t, errors.Is(err, ErrConversationRemoved), "got %v", err)
	assert.Zero(t, id)
	n, err := d.CountOpenCoachProposals()
	require.NoError(t, err)
	assert.Zero(t, n, "nothing filed")
}

func TestInsertChatCoachProposal_DeletedWorkbenchIsNotConversationRemoved(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	conv := newTuningConversation(t, d)
	p := chatSkillFixture("fp1", "a")
	p.WorkbenchID = 999_999 // no such workbench
	_, err := d.InsertChatCoachProposal(p, &conv, now)
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrConversationRemoved), "got %v", err)
	assert.True(t, IsForeignKeyViolation(err), "got %v", err)
}

func TestInsertChatCoachProposal_TextBusy(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	open, err := d.InsertCoachProposal(chatSkillFixture("fp-open", "a"), now)
	require.NoError(t, err)

	_, err = d.InsertChatCoachProposal(chatSkillFixture("fp-a", "a"), nil, now)
	require.True(t, errors.Is(err, ErrCoachTextBusy), "got %v", err)
	assert.Contains(t, err.Error(), fmt.Sprintf("#%d", open))

	id, err := d.InsertChatCoachProposal(chatSkillFixture("fp-b", "b"), nil, now)
	require.NoError(t, err)
	assert.NotZero(t, id, "another skill's text is free")

	// A decided proposal no longer holds the text.
	require.NoError(t, d.DecideCoachProposal(open, "open", "declined", now))
	id, err = d.InsertChatCoachProposal(chatSkillFixture("fp-a", "a"), nil, now)
	require.NoError(t, err)
	assert.NotZero(t, id)
}

func TestInsertChatCoachProposal_FingerprintConflictIsZero(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	first, err := d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), nil, now)
	require.NoError(t, err)
	require.NotZero(t, first)
	id, err := d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), nil, now)
	require.NoError(t, err, "a retry of the open proposal is a conflict, not busy")
	assert.Zero(t, id)
	require.NoError(t, d.DecideCoachProposal(first, "open", "declined", now))
	id, err = d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), nil, now)
	require.NoError(t, err)
	assert.Zero(t, id)
}

func TestCoachProposal_ConversationDeletedKeepsProposal(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	conv := newTuningConversation(t, d)
	id, err := d.InsertChatCoachProposal(chatSkillFixture("fp1", "a"), &conv, now)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Nil(t, got.ConversationID)
	assert.Equal(t, "open", got.Status)
}
