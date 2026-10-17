package db

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestReplaceReviewNotes_ReplacesTheSessionsSetOnly(t *testing.T) {
	d := openTestDB(t)
	pid, s1 := seedReviewSession(t, d)
	s2 := newTestSession(t, d, pid)
	require.NoError(t, d.ReplaceReviewNotes(pid, s2, "t0", []ReviewNote{{Kind: "note", Text: "other"}}))
	require.NoError(t, d.ReplaceReviewNotes(pid, s1, "t1", []ReviewNote{
		{Kind: "note", Path: "a.go", StartLine: 2, EndLine: 3, Quote: "q", Text: "first"},
		{Kind: "chapter", Text: "Core", Paths: []string{"a.go", "b.go"}, Core: true, Why: "w"},
		{Kind: "note", Text: "second"},
	}))
	require.NoError(t, d.ReplaceReviewNotes(pid, s1, "t2", []ReviewNote{{Kind: "note", Text: "only"}}))
	got, err := d.ReviewNotes(pid, s1)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "only", got[0].Text)
	assert.Equal(t, "t2", got[0].TreeSHA)
	other, err := d.ReviewNotes(pid, s2)
	require.NoError(t, err)
	require.Len(t, other, 1)

	require.NoError(t, d.ReplaceReviewNotes(pid, s1, "t3", []ReviewNote{
		{Kind: "note", Text: "n0"},
		{Kind: "chapter", Text: "c0", Paths: []string{"a.go"}, Core: true, Why: "w"},
		{Kind: "note", Text: "n1"},
	}))
	got, _ = d.ReviewNotes(pid, s1)
	require.Len(t, got, 3)
	assert.Equal(t, []string{"chapter", "note", "note"}, []string{got[0].Kind, got[1].Kind, got[2].Kind})
	assert.Equal(t, []int{0, 0, 1}, []int{got[0].Ord, got[1].Ord, got[2].Ord})
	assert.Equal(t, []string{"a.go"}, got[0].Paths)
	assert.True(t, got[0].Core)
}

func TestReviewOverview_PutAndGet(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	_, ok, err := d.ReviewOverviewJSON(pid, "t", "b", "h")
	require.NoError(t, err)
	assert.False(t, ok)
	require.NoError(t, d.PutReviewOverview(pid, "t", "b", "h", `{"a":1}`, "m"))
	require.NoError(t, d.PutReviewOverview(pid, "t", "b", "h", `{"a":2}`, "m"))
	js, ok, err := d.ReviewOverviewJSON(pid, "t", "b", "h")
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, `{"a":2}`, js)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM review_overviews`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestAddReviewRevert_SecondIsAlreadyReverted(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	rid, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	r := ReviewRevert{RoundID: rid, HunkID: "0123456789abcdef", Path: "a.go", Header: "@@ -1 +1 @@", Patch: "-a\n+b\n"}
	require.NoError(t, d.AddReviewRevert(r))
	err = d.AddReviewRevert(r)
	assert.True(t, errors.Is(err, ErrHunkAlreadyReverted), "%v", err)
	got, err := d.ReviewReverts(rid)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "-a\n+b\n", got[0].Patch)
	assert.NotEmpty(t, got[0].At)
}

func TestReplaceProposedReviewLessons_KeepsDecided(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	first, err := d.ReplaceProposedReviewLessons(pid, []ReviewLesson{{Lens: "tests", Text: "a", SourceCommentIDs: []int64{1}}, {Lens: "tests", Text: "b"}})
	require.NoError(t, err)
	require.Len(t, first, 2)
	assert.NotZero(t, first[0].ID)
	ok, err := d.DecideReviewLesson(pid, first[0].ID, "accepted")
	require.NoError(t, err)
	require.True(t, ok)
	second, err := d.ReplaceProposedReviewLessons(pid, []ReviewLesson{{Lens: "x", Text: "c"}})
	require.NoError(t, err)
	require.Len(t, second, 1)
	all, err := d.ReviewLessons(pid, "")
	require.NoError(t, err)
	assert.Len(t, all, 2)
	acc, _ := d.ReviewLessons(pid, "accepted")
	require.Len(t, acc, 1)
	assert.Equal(t, []int64{1}, acc[0].SourceCommentIDs)
	one, err := d.GetReviewLesson(pid, second[0].ID)
	require.NoError(t, err)
	assert.Equal(t, "c", one.Text)
	none, err := d.GetReviewLesson(pid+1, second[0].ID)
	require.NoError(t, err)
	assert.Nil(t, none)
}

func TestDecideReviewLesson_OnlyProposed(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	ls, err := d.ReplaceProposedReviewLessons(pid, []ReviewLesson{{Lens: "l", Text: "t"}})
	require.NoError(t, err)
	ok, err := d.DecideReviewLesson(pid, ls[0].ID, "dismissed")
	require.NoError(t, err)
	assert.True(t, ok)
	ok, err = d.DecideReviewLesson(pid, ls[0].ID, "accepted")
	require.NoError(t, err)
	assert.False(t, ok)
	var at *string
	require.NoError(t, d.QueryRow(`SELECT decided_at FROM review_lessons WHERE id = ?`, ls[0].ID).Scan(&at))
	assert.NotNil(t, at)
}

func TestReviewLessonInputComments_ExcludesDraftsCarriedOpenAndDecided(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	mkRound := func(status string) int64 {
		res, err := d.Exec(`INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status)
			VALUES (?, ?, '/r', 'b', 't', ?)`, pid, sid, status)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	mkComment := func(round int64, status string, carried any) int64 {
		res, err := d.Exec(`INSERT INTO review_comments (round_id, path, body, status, carried_from) VALUES (?, 'a.go', 'b', ?, ?)`, round, status, carried)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	oldest := mkRound("sent")
	oldC := mkComment(oldest, "sent", nil)
	for i := 0; i < 19; i++ {
		r := mkRound("delivered")
		mkComment(r, "sent", nil)
	}
	last := mkRound("delivered")
	good := mkComment(last, "resolved", nil)
	mkComment(last, "sent", nil) // second good one
	mkComment(last, "draft", nil)
	mkComment(last, "carried", nil)
	carriedCopy := mkComment(last, "sent", good)
	dismissed := mkComment(last, "sent", nil)
	open := mkRound("open")
	openC := mkComment(open, "sent", nil)
	_, err := d.ReplaceProposedReviewLessons(pid, []ReviewLesson{{Lens: "l", Text: "t", SourceCommentIDs: []int64{dismissed}}})
	require.NoError(t, err)
	ls, _ := d.ReviewLessons(pid, "proposed")
	_, err = d.DecideReviewLesson(pid, ls[0].ID, "dismissed")
	require.NoError(t, err)

	got, err := d.ReviewLessonInputComments(pid, 20)
	require.NoError(t, err)
	ids := map[int64]bool{}
	for _, c := range got {
		ids[c.ID] = true
	}
	assert.True(t, ids[good])
	for name, id := range map[string]int64{"oldest": oldC, "carried copy": carriedCopy, "dismissed": dismissed, "open round": openC} {
		assert.False(t, ids[id], name)
	}
	assert.Len(t, got, 21, fmt.Sprint(ids)) // 19 filler rounds + two kept comments of the last (21 sent rounds, newest 20)
}

func TestTerminalAgentWorking(t *testing.T) {
	d := openTestDB(t)
	_, sid := seedReviewSession(t, d)
	w, err := d.TerminalAgentWorking(sid)
	require.NoError(t, err)
	assert.False(t, w)
	_, err = d.Exec(`UPDATE terminal_sessions SET agent_state = 'working' WHERE id = ?`, sid)
	require.NoError(t, err)
	w, err = d.TerminalAgentWorking(sid)
	require.NoError(t, err)
	assert.True(t, w)
	w, err = d.TerminalAgentWorking(sid + 99)
	require.NoError(t, err)
	assert.False(t, w)
}
