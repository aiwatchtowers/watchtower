package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func lessonsJSONCall(t *testing.T, wb int64, sub string, args ...string) (map[string]any, error) {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"review", "lessons", sub, "--workbench", itoa(wb), "--json"}, args...)...)
	resetSetFlags(workbenchReviewLessonsCmd.Commands()...)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m, nil
}

// lessonComments: a sent round on the session holding n owner comments, plus
// a carried copy and a draft that must not reach the model.
func lessonComments(t *testing.T, database *db.DB, wb, session int64, n int) []int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status)
		VALUES (?, ?, '/r', 'b', 't', 'sent')`, wb, session)
	require.NoError(t, err)
	round, _ := res.LastInsertId()
	var ids []int64
	for range n {
		r, err := database.Exec(`INSERT INTO review_comments (round_id, path, body, status, lens) VALUES (?, 'a.go', ?, 'sent', 'tests')`, round, "needs a test")
		require.NoError(t, err)
		id, _ := r.LastInsertId()
		ids = append(ids, id)
	}
	if n > 0 {
		_, err = database.Exec(`INSERT INTO review_comments (round_id, path, body, status, carried_from) VALUES (?, 'a.go', 'copy', 'sent', ?)`, round, ids[0])
		require.NoError(t, err)
		_, err = database.Exec(`INSERT INTO review_comments (round_id, path, body, status) VALUES (?, 'a.go', 'draft', 'draft')`, round)
		require.NoError(t, err)
	}
	return ids
}

func lessonReply(ids []int64) string {
	b, _ := json.Marshal(map[string]any{"lessons": []map[string]any{
		{"lens": "tests", "text": "Does every change come with a test?", "source_comment_ids": ids},
	}})
	return string(b)
}

func TestWorkbenchReviewLessons_ProposeFeedsOnlyFreshSentComments(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	ids := lessonComments(t, database, wb, s, 3)
	// A decided lesson cites ids[2]: it is not fed again.
	saved, err := database.ReplaceProposedReviewLessons(wb, []db.ReviewLesson{{Lens: "tests", Text: "old?", SourceCommentIDs: []int64{ids[2]}}})
	require.NoError(t, err)
	_, err = database.DecideReviewLesson(wb, saved[0].ID, "dismissed")
	require.NoError(t, err)

	g := &fakeReviewGen{out: lessonReply(ids[:2])}
	useReviewGen(t, g)
	out, err := lessonsJSONCall(t, wb, "propose")
	require.NoError(t, err)
	require.Equal(t, true, out["ok"], out)
	require.Equal(t, 1, g.calls)
	for _, id := range ids[:2] {
		assert.Contains(t, g.users[0], "#"+itoa(id)+" ")
	}
	assert.NotContains(t, g.users[0], "#"+itoa(ids[2])+" ")
	assert.NotContains(t, g.users[0], "copy")
	assert.NotContains(t, g.users[0], "draft")
	lessons := out["lessons"].([]any)
	require.Len(t, lessons, 1)
	assert.Equal(t, "proposed", lessons[0].(map[string]any)["status"])
}

func TestWorkbenchReviewLessons_ProposeWithFewCommentsCallsNoModel(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	lessonComments(t, database, wb, s, 1)
	g := &fakeReviewGen{out: lessonReply(nil)}
	useReviewGen(t, g)
	out, err := lessonsJSONCall(t, wb, "propose")
	require.NoError(t, err)
	assert.Equal(t, true, out["ok"])
	assert.Equal(t, []any{}, out["lessons"])
	assert.Zero(t, g.calls)

	// A model reply with no groups also answers an explicit empty list.
	lessonComments(t, database, wb, s, 2)
	g.out = `{"lessons":[]}`
	out, err = lessonsJSONCall(t, wb, "propose")
	require.NoError(t, err)
	assert.Equal(t, 1, g.calls)
	assert.Equal(t, []any{}, out["lessons"])
}

// proposed: one proposed lesson on the workbench, ready to decide.
func proposed(t *testing.T, database *db.DB, wb int64) int64 {
	t.Helper()
	saved, err := database.ReplaceProposedReviewLessons(wb, []db.ReviewLesson{{Lens: "tests", Text: "Does every change come with a test?", SourceCommentIDs: []int64{1, 2}}})
	require.NoError(t, err)
	return saved[0].ID
}

func TestWorkbenchReviewLessons_AcceptWritesAndDecides(t *testing.T) {
	database, wb, _, repo := reviewFixture(t)
	id := proposed(t, database, wb)
	out, err := lessonsJSONCall(t, wb, "accept", "--lesson", itoa(id))
	require.NoError(t, err)
	require.Equal(t, true, out["ok"], out)
	assert.Equal(t, ".watchtower/review.md", out["written"])
	got, err := os.ReadFile(filepath.Join(repo, ".watchtower", "review.md"))
	require.NoError(t, err)
	assert.Equal(t, "## Tests\n- Does every change come with a test?\n", string(got))
	l, err := database.GetReviewLesson(wb, id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", l.Status)
}

func TestWorkbenchReviewLessons_AcceptRefusedUnderAgentMarkers(t *testing.T) {
	verbs := map[string]string{"accept": "accept a review lesson", "dismiss": "dismiss a review lesson", "propose": "propose review lessons"}
	for _, marker := range agentEnvMarkers {
		for sub, verb := range verbs {
			t.Run(marker+"/"+sub, func(t *testing.T) {
				database, wb, s, repo := reviewFixture(t)
				lessonComments(t, database, wb, s, 2)
				id := proposed(t, database, wb)
				g := &fakeReviewGen{out: `{"lessons":[]}`}
				useReviewGen(t, g)
				t.Setenv(marker, "1")
				args := []string{}
				if sub != "propose" {
					args = append(args, "--lesson", itoa(id))
				}
				_, err := lessonsJSONCall(t, wb, sub, args...)
				require.Error(t, err)
				assert.Contains(t, err.Error(), "refusing to "+verb)
				assert.Contains(t, err.Error(), marker)
				assert.Zero(t, g.calls, "no model call under %s", marker)
				_, statErr := os.Stat(filepath.Join(repo, ".watchtower", "review.md"))
				assert.True(t, os.IsNotExist(statErr))
				l, err := database.GetReviewLesson(wb, id)
				require.NoError(t, err)
				assert.Equal(t, "proposed", l.Status, "the proposed lesson is untouched under %s", marker)
			})
		}
	}
}

func TestWorkbenchReviewLessons_ReplyWithoutLessonsKeepsTheProposedRows(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	lessonComments(t, database, wb, s, 2)
	id := proposed(t, database, wb)
	g := &fakeReviewGen{out: `{}`}
	useReviewGen(t, g)
	out, err := lessonsJSONCall(t, wb, "propose")
	require.NoError(t, err)
	assert.Equal(t, false, out["ok"])
	assert.Contains(t, out["error"], "find repeats unavailable:")
	l, err := database.GetReviewLesson(wb, id)
	require.NoError(t, err)
	require.NotNil(t, l, "the earlier proposal stays")
	assert.Equal(t, "proposed", l.Status)
}

func TestWorkbenchReviewLessons_SecondAcceptWritesNoSecondCopy(t *testing.T) {
	database, wb, _, repo := reviewFixture(t)
	id := proposed(t, database, wb)
	out, err := lessonsJSONCall(t, wb, "accept", "--lesson", itoa(id))
	require.NoError(t, err)
	require.Equal(t, true, out["ok"], out)
	out, err = lessonsJSONCall(t, wb, "accept", "--lesson", itoa(id))
	require.NoError(t, err)
	assert.Equal(t, false, out["ok"])
	got, err := os.ReadFile(filepath.Join(repo, ".watchtower", "review.md"))
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(string(got), "- Does every change come with a test?"))
}

func TestWorkbenchReviewLessons_AppendFailureLeavesTheLessonProposed(t *testing.T) {
	database, wb, _, repo := reviewFixture(t)
	id := proposed(t, database, wb)
	// .watchtower is a plain file: the rule cannot be written.
	require.NoError(t, os.WriteFile(filepath.Join(repo, ".watchtower"), []byte("x"), 0o644))
	out, err := lessonsJSONCall(t, wb, "accept", "--lesson", itoa(id))
	require.NoError(t, err)
	assert.Equal(t, false, out["ok"])
	assert.Contains(t, out["error"], ".watchtower is not a real directory")
	l, err := database.GetReviewLesson(wb, id)
	require.NoError(t, err)
	assert.Equal(t, "proposed", l.Status)
}

// A cancel while Find repeats waits for the model ends the call.
func TestWorkbenchReviewLessons_CancelEndsTheModelCall(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	lessonComments(t, database, wb, s, 2)
	g := newBlockingReviewGen()
	useReviewGenerator(t, g)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := cancelWhileGenerating(t, g, cancel, func() (string, error) {
		return runReviewWithContext(t, ctx, workbenchReviewLessonsProposeCmd, "lessons", "propose", "--workbench", itoa(wb), "--json")
	})
	assert.Equal(t, false, out["ok"])
}

func TestWorkbenchReviewLessons_DecideOnlyProposed(t *testing.T) {
	database, wb, _, repo := reviewFixture(t)
	id := proposed(t, database, wb)
	out, err := lessonsJSONCall(t, wb, "dismiss", "--lesson", itoa(id))
	require.NoError(t, err)
	assert.Equal(t, true, out["ok"])
	for _, sub := range []string{"dismiss", "accept"} {
		out, err = lessonsJSONCall(t, wb, sub, "--lesson", itoa(id))
		require.NoError(t, err)
		assert.Equal(t, false, out["ok"], sub)
		assert.Equal(t, "lesson "+itoa(id)+" was already decided", out["error"], sub)
	}
	_, statErr := os.Stat(filepath.Join(repo, ".watchtower", "review.md"))
	assert.True(t, os.IsNotExist(statErr), "an already decided lesson writes nothing")
}
