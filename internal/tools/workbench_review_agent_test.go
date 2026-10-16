package tools

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// reviewRepoWorkbench is a workbench whose folder is a git repo with a.go
// (5 lines) committed and an uncommitted b.go (2 lines); the session env is a
// session of it.
func reviewRepoWorkbench(t *testing.T) (fx workbenchFixture, wb int64, session int64, reg *Registry) {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git not installed")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.com")
	dir := t.TempDir()
	git := func(args ...string) {
		cmd := exec.Command(bin, args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, string(out))
	}
	git("init", "-q", "-b", "main")
	require.NoError(t, os.WriteFile(filepath.Join(dir, "a.go"), []byte("one\ntwo\nthree\nfour\nfive\n"), 0o600))
	git("add", ".")
	git("commit", "-q", "-m", "init")
	require.NoError(t, os.WriteFile(filepath.Join(dir, "b.go"), []byte("alpha\nbeta\n"), 0o600))
	fx = newWorkbenchFixture(t)
	var err error
	wb, err = fx.d.CreateWorkbench("repo", dir)
	require.NoError(t, err)
	session = seedTerminalSession(t, fx.d, wb)
	return fx, wb, session, askRegistry(t, fx.d, strconv.FormatInt(session, 10))
}

func countNotes(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM review_notes`).Scan(&n))
	return n
}

func TestAnnotateChanges_StoresNotesWithQuotesAndReplaces(t *testing.T) {
	fx, wb, session, reg := reviewRepoWorkbench(t)
	out := mustApply(t, reg, wb, "annotate_changes", `{"notes":[
		{"path":"a.go","start_line":2,"end_line":3,"note":"why two and three"},
		{"path":"b.go","start_line":1,"end_line":1,"note":"first"}],
		"chapters":[{"title":"Core","paths":[" a.go ","a.go","b.go"],"core":true,"why":"the heart"}],
		"reason":"hand back"}`)
	assert.EqualValues(t, 2, out["notes"])
	assert.EqualValues(t, 1, out["chapters"])
	tree, _ := out["tree_sha"].(string)
	require.Len(t, tree, 40)
	assert.Equal(t, fmt.Sprintf("Stored 2 notes and 1 chapters for the current changes (tree %s). "+
		"They replace this session's earlier notes; the owner sees them in Review Changes.", tree[:7]), out["text"])

	notes, err := fx.d.ReviewNotes(wb, session)
	require.NoError(t, err)
	require.Len(t, notes, 3)
	byKind := map[string][]db.ReviewNote{}
	for _, n := range notes {
		assert.Equal(t, tree, n.TreeSHA)
		byKind[n.Kind] = append(byKind[n.Kind], n)
	}
	require.Len(t, byKind["note"], 2)
	assert.Equal(t, "two\nthree", strings.TrimRight(byKind["note"][0].Quote, "\n"))
	assert.Equal(t, "alpha", strings.TrimRight(byKind["note"][1].Quote, "\n"))
	require.Len(t, byKind["chapter"], 1)
	assert.Equal(t, []string{"a.go", "b.go"}, byKind["chapter"][0].Paths)
	assert.True(t, byKind["chapter"][0].Core)
	assert.Equal(t, "Core", byKind["chapter"][0].Text)

	mustApply(t, reg, wb, "annotate_changes", `{"notes":[{"path":"a.go","start_line":5,"end_line":5,"note":"only"}],"reason":"again"}`)
	notes, err = fx.d.ReviewNotes(wb, session)
	require.NoError(t, err)
	require.Len(t, notes, 1)
	assert.Equal(t, "only", notes[0].Text)
}

func TestAnnotateChanges_RefusesBadInputWithoutWriting(t *testing.T) {
	fx, wb, session, reg := reviewRepoWorkbench(t)
	other := seedTerminalSession(t, fx.d, fx.a)
	many := make([]string, 41)
	for i := range many {
		many[i] = `{"path":"a.go","start_line":1,"end_line":1,"note":"n"}`
	}
	one := func(path string, s, e int, note string) string {
		return fmt.Sprintf(`{"notes":[{"path":%q,"start_line":%d,"end_line":%d,"note":%q}],"reason":"r"}`, path, s, e, note)
	}
	for name, c := range map[string]struct {
		env  int64
		args string
		want string
	}{
		"line past EOF":     {session, one("a.go", 3, 6, "n"), "a.go"},
		"start after end":   {session, one("a.go", 4, 3, "n"), "a.go"},
		"unknown path":      {session, one("nope.go", 1, 1, "n"), "nope.go"},
		"empty note":        {session, one("a.go", 1, 1, "  "), "note"},
		"long note":         {session, one("a.go", 1, 1, strings.Repeat("ж", 801)), "note"},
		"41 notes":          {session, `{"notes":[` + strings.Join(many, ",") + `],"reason":"r"}`, "notes"},
		"nothing at all":    {session, `{"reason":"r"}`, "at least one"},
		"empty chapter":     {session, `{"chapters":[{"title":"T","paths":[],"core":false}],"reason":"r"}`, "paths"},
		"long reason":       {session, strings.Replace(one("a.go", 1, 1, "n"), `"reason":"r"`, `"reason":"`+strings.Repeat("r", 301)+`"`, 1), "reason"},
		"no session":        {0, one("a.go", 1, 1, "n"), "annotate_changes needs a Watchtower terminal session"},
		"another workbench": {other, one("a.go", 1, 1, "n"), "annotate_changes needs a Watchtower terminal session"},
	} {
		t.Run(name, func(t *testing.T) {
			env := ""
			if c.env != 0 {
				env = strconv.FormatInt(c.env, 10)
			}
			_, err := proposeIn(t, askRegistry(t, fx.d, env), wb, "annotate_changes", c.args)
			require.Error(t, err)
			assert.Contains(t, err.Error(), c.want)
			assert.Zero(t, countNotes(t, fx.d))
			assert.Zero(t, countActions(t, fx.d), "a refused call writes no audit row")
		})
	}
	_ = reg
}

// seedReplyRound: a sent round with one comment, and the session's open round
// holding a carried copy of it.
func seedReplyRound(t *testing.T, d *db.DB, wb int64) (comment, copyID int64) {
	t.Helper()
	sid := seedTerminalSession(t, d, wb)
	sent := seedSentReviewRoundFor(t, d, wb, sid)
	require.NoError(t, d.QueryRow(`SELECT id FROM review_comments WHERE round_id = ?`, sent).Scan(&comment))
	open, err := d.CreateReviewRound(db.ReviewRound{ProjectID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", TreeSHA: "t2"})
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO review_comments (round_id, path, body, status, carried_from) VALUES (?, 'a.go', 'rename x', 'carried', ?)`, open, comment)
	require.NoError(t, err)
	copyID, _ = res.LastInsertId()
	return comment, copyID
}

func seedSentReviewRoundFor(t *testing.T, d *db.DB, wb, sid int64) int64 {
	t.Helper()
	rid, err := d.CreateReviewRound(db.ReviewRound{ProjectID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", BaseLabel: "main", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body) VALUES (?, 'a.go', 1, 1, 'x', 'rename x')`, rid)
	require.NoError(t, err)
	_, ok, err := d.SendReviewRound(wb, rid)
	require.NoError(t, err)
	require.True(t, ok)
	return rid
}

func commentState(t *testing.T, d *db.DB, id int64) (status, reply string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT status, agent_reply FROM review_comments WHERE id = ?`, id).Scan(&status, &reply))
	return
}

func TestReplyReviewComment_RepliesResolvesAndFollowsTheOpenCopy(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	comment, copyID := seedReplyRound(t, fx.d, fx.a)

	out := mustApply(t, reg, fx.a, "reply_review_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"renamed it","resolved":false,"reason":"answer"}`, comment))
	assert.Equal(t, true, out["replied"])
	for _, id := range []int64{comment, copyID} {
		st, reply := commentState(t, fx.d, id)
		assert.Equal(t, "renamed it", reply)
		assert.NotEqual(t, "resolved", st)
	}
	mustApply(t, reg, fx.a, "reply_review_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"done","resolved":true,"reason":"fixed"}`, comment))
	for _, id := range []int64{comment, copyID} {
		st, reply := commentState(t, fx.d, id)
		assert.Equal(t, []string{"resolved", "done"}, []string{st, reply})
	}

	ownerCopy := func() int64 {
		c2, copy2 := seedReplyRound(t, fx.d, fx.a)
		_, err := fx.d.Exec(`UPDATE review_comments SET status = 'resolved' WHERE id = ?`, copy2)
		require.NoError(t, err)
		mustApply(t, reg, fx.a, "reply_review_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"hi","resolved":true,"reason":"r"}`, c2))
		return copy2
	}()
	_, reply := commentState(t, fx.d, ownerCopy)
	assert.Empty(t, reply, "an owner-resolved copy is untouched")
}

func TestReplyReviewComment_RefusesDraftsOpenRoundsAndOtherWorkbenches(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	comment, copyID := seedReplyRound(t, fx.d, fx.a)
	args := func(id int64) string {
		return fmt.Sprintf(`{"comment_id":%d,"reply":"x","resolved":true,"reason":"r"}`, id)
	}
	// The carried copy sits in the open round: not repliable.
	_, err := proposeIn(t, reg, fx.a, "reply_review_comment", args(copyID))
	assert.Equal(t, fmt.Sprintf("comment %d is not in a sent review round of this workbench", copyID), refusal(t, err))
	// Another workbench's comment.
	_, err = proposeIn(t, reg, fx.b, "reply_review_comment", args(comment))
	assert.Equal(t, fmt.Sprintf("comment %d is not in a sent review round of this workbench", comment), refusal(t, err))
	_, err = proposeIn(t, reg, fx.a, "reply_review_comment", args(99999))
	require.Error(t, err)
	// Bounds.
	_, err = proposeIn(t, reg, fx.a, "reply_review_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"","resolved":true,"reason":"r"}`, comment))
	require.Error(t, err)
	_, err = proposeIn(t, reg, fx.a, "reply_review_comment", fmt.Sprintf(`{"comment_id":%d,"reply":%q,"resolved":true,"reason":"r"}`, comment, strings.Repeat("ж", 2001)))
	require.Error(t, err)
	st, reply := commentState(t, fx.d, comment)
	assert.Equal(t, []string{"sent", ""}, []string{st, reply})
	assert.Zero(t, countActions(t, fx.d), "refused calls write no audit row")
}

func TestGetReview_ListsReverts(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 1, 1, "q", "c")
	got := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	assert.NotContains(t, got, "Undone by the owner")
	assert.Contains(t, got, `"reverts":[]`)

	require.NoError(t, fx.d.AddReviewRevert(db.ReviewRevert{RoundID: rid, HunkID: "0123456789abcdef", Path: "a.go",
		Header: "@@ -1,2 +1,3 @@", Patch: "-old\n+new\n"}))
	got = callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	var v reviewView
	require.NoError(t, json.Unmarshal([]byte(got), &v))
	require.Len(t, v.Reverts, 1)
	assert.Equal(t, "0123456789abcdef", v.Reverts[0].HunkID)
	assert.Contains(t, v.Text, "Undone by the owner (reverted in the work tree — do not redo without asking):\n- a.go @@ -1,2 +1,3 @@\n  -old\n  +new\n")
	assert.True(t, strings.HasSuffix(v.Text, "  +new\n"), v.Text)
}
