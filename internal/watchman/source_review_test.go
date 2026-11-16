package watchman

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedRound inserts a review round of workbench wb; sentAt nil = still open.
func seedRound(t *testing.T, d *db.DB, wb int64, status, outcome string, sentAt *time.Time) int64 {
	t.Helper()
	var sent any
	if sentAt != nil {
		sent = stamp(*sentAt)
	}
	res, err := d.Exec(`INSERT INTO review_rounds (project_id, folder_root, base_sha, base_label, tree_sha, status, outcome, sent_at, branch)
		VALUES (?, '/tmp/acme', 'b0', 'main', 't0', ?, ?, ?, 'feature/importer')`, wb, status, outcome, sent)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func seedComment(t *testing.T, d *db.DB, round int64, path, quote, body, status string, carriedFrom any) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO review_comments (round_id, path, quote, lens, body, status, carried_from) VALUES (?, ?, ?, 'naming', ?, ?, ?)`,
		round, path, quote, body, status, carriedFrom)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func seedRevert(t *testing.T, d *db.DB, round int64, hunk string, at time.Time) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO review_reverts (round_id, hunk_id, path, header, patch, at) VALUES (?, ?, 'cmd/import.go', '@@ -1,3 +1,4 @@', '+retry(3)', ?)`,
		round, hunk, stamp(at))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func seedLesson(t *testing.T, d *db.DB, wb int64, text, status string, decidedAt *time.Time) int64 {
	t.Helper()
	var at any
	if decidedAt != nil {
		at = stamp(*decidedAt)
	}
	res, err := d.Exec(`INSERT INTO review_lessons (project_id, lens, text, status, decided_at) VALUES (?, 'tests', ?, ?, ?)`, wb, text, status, at)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func byKey(ps []db.WatchmanPrecedent) map[string]db.WatchmanPrecedent {
	m := map[string]db.WatchmanPrecedent{}
	for _, p := range ps {
		m[p.SourceKey] = p
	}
	return m
}

func TestReviewSource_MapsRows(t *testing.T) {
	d := openSourceDB(t)
	t1, t2 := srcT0, srcT0.Add(time.Hour)
	changes := seedRound(t, d, 1, "delivered", "changes", &t1)
	c := seedComment(t, d, changes, "cmd/import.go", "retry(3)", "why three?", "sent", nil)
	seedComment(t, d, changes, "cmd/import.go", "old", "never sent", "outdated", nil)
	approved := seedRound(t, d, 1, "sent", "approved", &t2)
	seedComment(t, d, approved, "cmd/import.go", "retry(3)", "why three?", "resolved", c) // a carried copy
	open := seedRound(t, d, 1, "open", "", nil)
	seedComment(t, d, open, "cmd/import.go", "x", "draft", "draft", nil)
	v := seedRevert(t, d, open, "h1", srcT0.Add(30*time.Minute))
	other := seedRound(t, d, 2, "sent", "changes", &t1)
	seedComment(t, d, other, "x.go", "", "another workbench", "sent", nil)

	ps, _, done, err := reviewSource{}.Next(context.Background(), d, 1, "", 20)
	require.NoError(t, err)
	require.True(t, done)
	got := byKey(ps)
	require.Len(t, got, 4, "%v", keys(ps))

	cm := got[fmt.Sprintf("comment:%d", c)]
	require.Equal(t, "review", cm.Source)
	require.Equal(t, "review_code", cm.Category)
	require.Equal(t, "comment", cm.Choice)
	require.Equal(t, "why three?", cm.OwnerWords)
	require.Equal(t, "cmd/import.go\nLens: naming\nretry(3)", cm.Situation)
	require.Equal(t, t1, cm.DecidedAt)

	rc := got[fmt.Sprintf("round:%d", changes)]
	require.Equal(t, "changes", rc.Choice)
	require.Contains(t, rc.Situation, "Review round of feature/importer")
	require.Contains(t, rc.Situation, "1 comments")
	require.Contains(t, rc.Situation, "Files: cmd/import.go")
	require.Equal(t, "why three?", rc.OwnerWords)

	ra := got[fmt.Sprintf("round:%d", approved)]
	require.Equal(t, "approve", ra.Choice)
	require.Contains(t, ra.Situation, "0 comments")
	require.Equal(t, t2, ra.DecidedAt)

	rv := got[fmt.Sprintf("revert:%d", v)]
	require.Equal(t, "undid hunk", rv.Choice)
	require.Equal(t, 2.0, rv.Weight)
	require.Equal(t, "cmd/import.go\n@@ -1,3 +1,4 @@\n+retry(3)", rv.Situation)
}

func TestReviewSource_IncludesLessons(t *testing.T) {
	d := openSourceDB(t)
	t1, t2 := srcT0, srcT0.Add(time.Hour)
	acc := seedLesson(t, d, 1, "Every retry has a test.", "accepted", &t1)
	dis := seedLesson(t, d, 1, "Name every constant.", "dismissed", &t2)
	seedLesson(t, d, 1, "Still proposed.", "proposed", nil)
	seedLesson(t, d, 2, "Another workbench.", "accepted", &t1)

	ps, _, _, err := reviewSource{}.Next(context.Background(), d, 1, "", 20)
	require.NoError(t, err)
	require.Equal(t, []string{fmt.Sprintf("lesson:%d", dis), fmt.Sprintf("lesson:%d", acc)}, keys(ps))
	require.Equal(t, "dismissed", ps[0].Choice)
	require.Equal(t, "accepted", ps[1].Choice)
	require.Equal(t, "Lens: tests\nEvery retry has a test.", ps[1].Situation)
	require.Equal(t, "review_code", ps[1].Category)
}

func TestReviewSource_CursorNewestFirst(t *testing.T) {
	d := openSourceDB(t)
	round := seedRound(t, d, 1, "open", "", nil)
	checkNewestFirst(t, d, reviewSource{}, func(i int, at time.Time) string {
		return fmt.Sprintf("revert:%d", seedRevert(t, d, round, fmt.Sprintf("h%d", i), at))
	})
}
