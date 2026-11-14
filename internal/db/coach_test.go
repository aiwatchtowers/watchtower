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
	require.NoError(t, d.MarkCoachAccepted(id, "after edited", "", &base, 4, now.Add(time.Hour)))
	acc, err := d.ListCoachProposals("accepted")
	require.NoError(t, err)
	require.Len(t, acc, 1)
	require.NotNil(t, acc[0].Baseline)
	assert.Equal(t, 2.5, *acc[0].Baseline)
	assert.Equal(t, 4, acc[0].BaselineN)
	assert.Equal(t, "after edited", acc[0].AfterText)
	assert.Error(t, d.MarkCoachAccepted(id, "x", "", nil, 1, now), "only from open")

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

// A workbench repository edit stores its branch at Accept; measure_from is set
// once, only while accepted; the awaiting list holds accepted repo_* rows with
// no measure_from and no verdict.
func TestCoachProposal_WrittenBranchAndMeasureFrom(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	repo := func(fp string) int64 {
		p := coachFixture(fp)
		p.Destination, p.WorkbenchID = "repo_claude_md", wb
		id, err := d.InsertCoachProposal(p, now)
		require.NoError(t, err)
		return id
	}
	a, b, c, rolled := repo("r1"), repo("r2"), repo("r3"), repo("r4")
	open := repo("r5")
	other, err := d.InsertCoachProposal(coachFixture("s1"), now)
	require.NoError(t, err)
	for _, id := range []int64{a, b, c, rolled, other} {
		require.NoError(t, d.MarkCoachAccepted(id, "a\nb", "feature/x", nil, 0, now))
	}
	require.NoError(t, d.SetCoachVerdict(c, "too_little_data", nil, now.Add(31*24*time.Hour)))
	require.NoError(t, d.DecideCoachProposal(rolled, "accepted", "rolled_back", now))

	got, err := d.GetCoachProposal(a)
	require.NoError(t, err)
	assert.Equal(t, "feature/x", got.WrittenBranch)
	assert.True(t, got.MeasureFrom.IsZero())

	awaiting, err := d.ListRepoProposalsAwaitingCommit()
	require.NoError(t, err)
	var ids []int64
	for _, p := range awaiting {
		ids = append(ids, p.ID)
	}
	assert.Equal(t, []int64{a, b}, ids, "not the judged, rolled back, open or non-repo rows (%d, %d, %d, %d)", c, rolled, open, other)

	at := now.Add(48 * time.Hour)
	set, err := d.SetCoachMeasureFrom(a, at)
	require.NoError(t, err)
	assert.True(t, set)
	set, err = d.SetCoachMeasureFrom(a, at.Add(time.Hour))
	require.NoError(t, err)
	assert.False(t, set, "set once")
	set, err = d.SetCoachMeasureFrom(rolled, at)
	require.NoError(t, err)
	assert.False(t, set, "only while accepted")
	set, err = d.SetCoachMeasureFrom(c, at)
	require.NoError(t, err)
	assert.False(t, set, "not after a verdict (the judge raced the commit check)")
	got, err = d.GetCoachProposal(a)
	require.NoError(t, err)
	assert.Equal(t, at, got.MeasureFrom.UTC())

	awaiting, err = d.ListRepoProposalsAwaitingCommit()
	require.NoError(t, err)
	require.Len(t, awaiting, 1)
	assert.Equal(t, b, awaiting[0].ID)
}

func contextFixture(fp, dest, sourceKey string) CoachProposal {
	p := coachFixture(fp)
	p.Kind, p.Destination, p.SourceKey, p.Metric = "cut", dest, sourceKey, "start_tokens"
	return p
}

// One open context proposal per (destination, source_key[, workbench]); a
// decided one frees its source, another source is free meanwhile.
func TestInsertContextCoachProposal_OnePerSource(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	open, err := d.InsertContextCoachProposal(contextFixture("fp-a", "claude_plugin_off", "alpha@market"), now)
	require.NoError(t, err)
	require.NotZero(t, open)
	got, err := d.GetCoachProposal(open)
	require.NoError(t, err)
	assert.Equal(t, "context", got.Origin)
	assert.Equal(t, "alpha@market", got.SourceKey)
	assert.Equal(t, "start_tokens", got.Metric)
	assert.Nil(t, got.SessionID)
	assert.False(t, got.ViaSession)
	assert.Equal(t, "", got.SessionBranch)

	_, err = d.InsertContextCoachProposal(contextFixture("fp-a2", "claude_plugin_off", "alpha@market"), now)
	require.True(t, errors.Is(err, ErrCoachTextBusy), "got %v", err)
	assert.Contains(t, err.Error(), fmt.Sprintf("#%d", open))

	other, err := d.InsertContextCoachProposal(contextFixture("fp-b", "claude_plugin_off", "beta@market"), now)
	require.NoError(t, err)
	assert.NotZero(t, other, "another plugin is free")

	// Per-workbench destinations: one open per workbench.
	mem := contextFixture("fp-m1", "claude_memory_index", "memory")
	mem.Kind, mem.WorkbenchID = "restructure", wb
	m1, err := d.InsertContextCoachProposal(mem, now)
	require.NoError(t, err)
	require.NotZero(t, m1)
	mem.Fingerprint = "fp-m2"
	_, err = d.InsertContextCoachProposal(mem, now)
	require.True(t, errors.Is(err, ErrCoachTextBusy), "got %v", err)
	wb2 := newTestWorkbench(t, d)
	mem.Fingerprint, mem.WorkbenchID = "fp-m3", wb2
	m3, err := d.InsertContextCoachProposal(mem, now)
	require.NoError(t, err)
	assert.NotZero(t, m3, "another workbench's index is free")
	got, err = d.GetCoachProposal(m3)
	require.NoError(t, err)
	assert.Equal(t, wb2, got.WorkbenchID, "a per-workbench destination keeps its workbench")

	require.NoError(t, d.DecideCoachProposal(open, "open", "declined", now))
	again, err := d.InsertContextCoachProposal(contextFixture("fp-a3", "claude_plugin_off", "alpha@market"), now)
	require.NoError(t, err)
	assert.NotZero(t, again, "a decided proposal no longer holds the source")
}

// A global destination filed from two workbenches is one row, stored without
// a workbench.
func TestInsertContextCoachProposal_GlobalOncePerInstall(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb1, wb2 := newTestWorkbench(t, d), newTestWorkbench(t, d)
	for _, dest := range []string{"claude_plugin_off", "claude_mcp_server_off", "claude_connectors_off"} {
		p := contextFixture("fp-1-"+dest, dest, "src")
		p.WorkbenchID = wb1
		first, err := d.InsertContextCoachProposal(p, now)
		require.NoError(t, err, dest)
		require.NotZero(t, first, dest)
		p.Fingerprint, p.WorkbenchID = "fp-2-"+dest, wb2
		_, err = d.InsertContextCoachProposal(p, now)
		require.True(t, errors.Is(err, ErrCoachTextBusy), "%s: got %v", dest, err)
		got, err := d.GetCoachProposal(first)
		require.NoError(t, err)
		assert.Zero(t, got.WorkbenchID, "%s is stored without a workbench", dest)
	}
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM coach_proposals WHERE workbench_id IS NOT NULL`).Scan(&n))
	assert.Zero(t, n)
}

func TestInsertContextCoachProposal_FingerprintNoop(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	first, err := d.InsertContextCoachProposal(contextFixture("fp1", "claude_connectors_off", "connectors"), now)
	require.NoError(t, err)
	require.NotZero(t, first)
	id, err := d.InsertContextCoachProposal(contextFixture("fp1", "claude_connectors_off", "connectors"), now)
	require.NoError(t, err, "a retry of the open proposal is a conflict, not busy")
	assert.Zero(t, id)
	require.NoError(t, d.DecideCoachProposal(first, "open", "declined", now))
	id, err = d.InsertContextCoachProposal(contextFixture("fp1", "claude_connectors_off", "connectors"), now)
	require.NoError(t, err)
	assert.Zero(t, id)
}

// The Desktop deletes terminal_sessions rows: session_id goes NULL, but
// via_session and session_branch stay, so the row still reads as accepted
// through a session and its PR can still be found by branch.
func TestCoachProposal_SessionDeletedKeepsViaSessionAndBranch(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	sess := newTestSession(t, d, wb)
	p := contextFixture("fp1", "claude_memory_index", "memory")
	p.Kind, p.WorkbenchID = "restructure", wb
	id, err := d.InsertContextCoachProposal(p, now)
	require.NoError(t, err)
	require.NoError(t, d.AcceptCoachThroughSession(id, CoachSessionLink{SessionID: sess, WorkbenchID: wb}, now))
	require.NoError(t, d.SetCoachSessionBranch(id, "wt/slim-memory"))

	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sess)
	require.NoError(t, err)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Nil(t, got.SessionID)
	assert.True(t, got.ViaSession)
	assert.Equal(t, "wt/slim-memory", got.SessionBranch)
	assert.Equal(t, "accepted", got.Status)
}

// SetCoachSessionBranch only fills an empty branch.
func TestSetCoachSessionBranch_OnlyFillsEmpty(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	p := contextFixture("fp1", "repo_claude_md", "")
	p.Kind, p.WorkbenchID = "restructure", wb
	id, err := d.InsertContextCoachProposal(p, now)
	require.NoError(t, err)

	require.NoError(t, d.SetCoachSessionBranch(id, "feature/a"))
	require.NoError(t, d.SetCoachSessionBranch(id, "feature/b"))
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "feature/a", got.SessionBranch, "the first branch is kept")
}

// sessionContextProposal files an open restructure proposal of dest in
// workbench wb.
func sessionContextProposal(t *testing.T, d *DB, fp, dest string, wb int64, now time.Time) int64 {
	t.Helper()
	p := contextFixture(fp, dest, "")
	p.Kind, p.WorkbenchID = "restructure", wb
	if dest == "claude_memory_index" {
		p.SourceKey = "memory"
	}
	id, err := d.InsertContextCoachProposal(p, now)
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

func recordSessionBranch(t *testing.T, d *DB, sess int64, root, branch, at string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at) VALUES (?, ?, ?, ?)`,
		sess, root, branch, at)
	require.NoError(t, err)
}

// An Accept through a session records the session, its latest worktree
// branch, the baseline and (memory) the index read at Accept in one
// compare-and-set; a session of another workbench is refused, a second Accept
// is state_changed.
func TestAcceptCoachThroughSession(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	sess := newTestSession(t, d, wb)
	foreign := newTestSession(t, d, other)
	recordSessionBranch(t, d, sess, "/tmp/acme", "main", "2026-11-12T08:00:00.000Z")
	recordSessionBranch(t, d, sess, "/tmp/acme-wt", "wt/slim", "2026-11-12T08:30:00.000Z")
	recordSessionBranch(t, d, sess, "/tmp/acme-wt2", "", "2026-11-12T08:40:00.000Z")
	id := sessionContextProposal(t, d, "fp1", "claude_memory_index", wb, now)

	err := d.AcceptCoachThroughSession(id, CoachSessionLink{SessionID: foreign, WorkbenchID: wb}, now)
	require.ErrorIs(t, err, ErrCoachSessionNotFound)
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "open", got.Status)

	before, base := "- line one\n", 900.0
	require.NoError(t, d.AcceptCoachThroughSession(id, CoachSessionLink{SessionID: sess, WorkbenchID: wb,
		Before: &before, Baseline: &base, N: 6}, now))
	got, err = d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", got.Status)
	assert.True(t, got.ViaSession)
	require.NotNil(t, got.SessionID)
	assert.Equal(t, sess, *got.SessionID)
	assert.Equal(t, "wt/slim", got.SessionBranch, "the latest named branch")
	assert.Equal(t, before, got.BeforeText)
	require.NotNil(t, got.Baseline)
	assert.InDelta(t, base, *got.Baseline, 1e-9)
	assert.Equal(t, 6, got.BaselineN)
	assert.True(t, got.DecidedAt.Equal(now))

	err = d.AcceptCoachThroughSession(id, CoachSessionLink{SessionID: sess, WorkbenchID: wb}, now)
	require.ErrorIs(t, err, ErrCoachStateChanged)

	legacy, err := d.InsertCoachProposal(coachFixture("fp-legacy"), now)
	require.NoError(t, err)
	require.NoError(t, d.MarkCoachAccepted(legacy, "a\nb", "", nil, 0, now))
	got, err = d.GetCoachProposal(legacy)
	require.NoError(t, err)
	assert.False(t, got.ViaSession, "an ordinary Accept is not via a session")
	assert.Nil(t, got.SessionID)

	// No recorded branch yet: session_branch stays empty, before_text kept.
	id2 := sessionContextProposal(t, d, "fp2", "repo_claude_md", wb, now)
	sess2 := newTestSession(t, d, wb)
	require.NoError(t, d.AcceptCoachThroughSession(id2, CoachSessionLink{SessionID: sess2, WorkbenchID: wb}, now))
	got, err = d.GetCoachProposal(id2)
	require.NoError(t, err)
	assert.Empty(t, got.SessionBranch)
	assert.Equal(t, "a", got.BeforeText)
}

func acceptedThroughSession(t *testing.T, d *DB, fp, dest string, wb, sess int64, now time.Time) int64 {
	t.Helper()
	id := sessionContextProposal(t, d, fp, dest, wb, now)
	require.NoError(t, d.AcceptCoachThroughSession(id, CoachSessionLink{SessionID: sess, WorkbenchID: wb}, now))
	return id
}

// Dismiss closes an accepted session row with nothing to measure as
// too_little_data; a measured, judged, legacy or open row is refused.
func TestDismissCoachSession(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	wb := newTestWorkbench(t, d)
	sess := newTestSession(t, d, wb)
	id := acceptedThroughSession(t, d, "fp1", "repo_claude_md", wb, sess, now)

	require.NoError(t, d.DismissCoachSession(id, now.Add(time.Hour)))
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", got.Status)
	assert.Equal(t, "too_little_data", got.Verdict)
	assert.Nil(t, got.VerdictValue)
	assert.True(t, got.VerdictAt.Equal(now.Add(time.Hour)))
	require.ErrorIs(t, d.DismissCoachSession(id, now), ErrCoachStateChanged, "already judged")

	measured := acceptedThroughSession(t, d, "fp2", "claude_memory_index", wb, sess, now)
	ok, err := d.SetCoachMeasureFrom(measured, now)
	require.NoError(t, err)
	require.True(t, ok)
	require.ErrorIs(t, d.DismissCoachSession(measured, now), ErrCoachStateChanged)

	open := sessionContextProposal(t, d, "fp3", "repo_claude_md", wb, now)
	require.ErrorIs(t, d.DismissCoachSession(open, now), ErrCoachStateChanged)

	legacy, err := d.InsertCoachProposal(coachFixture("fp-legacy"), now)
	require.NoError(t, err)
	require.NoError(t, d.MarkCoachAccepted(legacy, "a\nb", "", nil, 0, now))
	require.ErrorIs(t, d.DismissCoachSession(legacy, now), ErrCoachStateChanged)
}

// Restart moves an accepted session row to a new session: session, branch,
// decided_at, baseline and (memory) before_text replaced; refused while the
// old session's branch has an open or merged PR, and on a measured row.
func TestRestartCoachSession(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	later := now.Add(28 * 24 * time.Hour)
	wb := newTestWorkbench(t, d)
	old := newTestSession(t, d, wb)
	recordSessionBranch(t, d, old, "/tmp/a", "wt/first", "2026-11-12T08:00:00.000Z")
	id := acceptedThroughSession(t, d, "fp1", "claude_memory_index", wb, old, now)

	fresh := newTestSession(t, d, wb)
	recordSessionBranch(t, d, fresh, "/tmp/b", "wt/second", "2026-12-10T08:00:00.000Z")
	before, base := "- new\n", 500.0
	require.NoError(t, d.RestartCoachSession(id, CoachSessionLink{SessionID: fresh, WorkbenchID: wb,
		Before: &before, Baseline: &base, N: 5}, later))
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", got.Status)
	require.NotNil(t, got.SessionID)
	assert.Equal(t, fresh, *got.SessionID)
	assert.Equal(t, "wt/second", got.SessionBranch)
	assert.True(t, got.DecidedAt.Equal(later))
	assert.Equal(t, before, got.BeforeText)
	require.NotNil(t, got.Baseline)
	assert.InDelta(t, base, *got.Baseline, 1e-9)

	// The new session's branch has an open PR now: no third start.
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: wb, Ref: "branch:wt/second", State: "open",
		PRNumber: sql.NullInt64{Int64: 12, Valid: true}, CheckedAt: "2026-12-10T09:00:00Z"}))
	third := newTestSession(t, d, wb)
	err = d.RestartCoachSession(id, CoachSessionLink{SessionID: third, WorkbenchID: wb}, later)
	require.ErrorIs(t, err, ErrCoachSessionHasPR)

	// A closed PR does not hold a restart back.
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: wb, Ref: "branch:wt/second", State: "closed",
		PRNumber: sql.NullInt64{Int64: 12, Valid: true}, CheckedAt: "2026-12-10T10:00:00Z"}))
	require.NoError(t, d.RestartCoachSession(id, CoachSessionLink{SessionID: third, WorkbenchID: wb}, later))
	got, err = d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Empty(t, got.SessionBranch, "cleared: the third session has no branch yet")
	assert.Equal(t, before, got.BeforeText, "nil Before keeps the text")

	// Another workbench's session, and a measured row, are refused.
	other := newTestWorkbench(t, d)
	require.ErrorIs(t, d.RestartCoachSession(id, CoachSessionLink{SessionID: newTestSession(t, d, other), WorkbenchID: wb}, later),
		ErrCoachSessionNotFound)
	ok, err := d.SetCoachMeasureFrom(id, later)
	require.NoError(t, err)
	require.True(t, ok)
	require.ErrorIs(t, d.RestartCoachSession(id, CoachSessionLink{SessionID: fresh, WorkbenchID: wb}, later),
		ErrCoachStateChanged)
}

// Reapply clears a reverted_outside verdict and restarts the window; any
// other row is refused.
func TestReapplyCoachProposal(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	id, err := d.InsertContextCoachProposal(contextFixture("fp1", "claude_plugin_off", "alpha@market"), now)
	require.NoError(t, err)
	require.ErrorIs(t, d.ReapplyCoachProposal(id, now), ErrCoachStateChanged, "open")
	require.NoError(t, d.MarkCoachAccepted(id, "false", "", nil, 0, now))
	require.ErrorIs(t, d.ReapplyCoachProposal(id, now), ErrCoachStateChanged, "no verdict")
	v := 1.0
	require.NoError(t, d.SetCoachVerdict(id, "reverted_outside", &v, now))

	at := now.Add(48 * time.Hour)
	require.NoError(t, d.ReapplyCoachProposal(id, at))
	got, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", got.Status)
	assert.Empty(t, got.Verdict)
	assert.Nil(t, got.VerdictValue)
	assert.True(t, got.VerdictAt.IsZero())
	assert.True(t, got.MeasureFrom.Equal(at))
	require.ErrorIs(t, d.ReapplyCoachProposal(id, at), ErrCoachStateChanged, "verdict cleared already")
}

// CoachSessionBranch is a session's latest named worktree branch; "" when it
// has none (or no such session).
func TestCoachSessionBranch(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	sess := newTestSession(t, d, wb)
	b, err := d.CoachSessionBranch(sess)
	require.NoError(t, err)
	assert.Empty(t, b)
	recordSessionBranch(t, d, sess, "/tmp/a", "wt/one", "2026-11-12T08:00:00.000Z")
	_, err = d.Exec(`UPDATE terminal_session_worktrees SET last_at = '2026-11-12T10:00:00.000Z'`)
	require.NoError(t, err)
	recordSessionBranch(t, d, sess, "/tmp/b", "wt/two", "2026-11-12T09:00:00.000Z")
	b, err = d.CoachSessionBranch(sess)
	require.NoError(t, err)
	assert.Equal(t, "wt/one", b, "last seen wins over first seen")
	b, err = d.CoachSessionBranch(9999)
	require.NoError(t, err)
	assert.Empty(t, b)
}
