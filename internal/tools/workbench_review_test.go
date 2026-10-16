package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedSentReviewRound: a session on workbench wb, a round with one comment
// (path, lines, quote, body), sent.
func seedSentReviewRound(t *testing.T, d *db.DB, wb int64, path string, start, end int, quote, body string) int64 {
	t.Helper()
	sid := seedTerminalSession(t, d, wb)
	rid, err := d.CreateReviewRound(db.ReviewRound{ProjectID: wb, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", BaseLabel: "main", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body) VALUES (?, ?, ?, ?, ?, ?)`,
		rid, path, start, end, quote, body)
	require.NoError(t, err)
	_, ok, err := d.SendReviewRound(wb, rid)
	require.NoError(t, err)
	require.True(t, ok)
	return rid
}

func TestGetReview_ReadsCommentsAndMarksDelivered(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 10, 12, "x := 1", "rename x")
	got := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	var v reviewView
	require.NoError(t, json.Unmarshal([]byte(got), &v))
	assert.Equal(t, "delivered", v.Status)
	require.Len(t, v.Comments, 1)
	assert.Equal(t, "rename x", v.Comments[0].Body)
	assert.Contains(t, v.Text, "a.go:10-12")
	assert.Contains(t, v.Text, "> x := 1")
	r, err := fx.d.GetReviewRound(fx.a, rid)
	require.NoError(t, err)
	assert.Equal(t, "delivered", r.Status)

	again := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	assert.Contains(t, again, "rename x", "a delivered round reads again")
}

func TestGetReview_OtherWorkbenchRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 1, 1, "q", "c")
	_, err := reg.CallRead(context.Background(), "get_review", json.RawMessage(fmt.Sprintf(`{"round_id":%d}`, rid)), directBinding(fx.b))
	require.Error(t, err)
	r, _ := fx.d.GetReviewRound(fx.a, rid)
	assert.Equal(t, "sent", r.Status, "a refused read delivers nothing")
}

func TestGetReview_OpenRoundAndDraftsStayHidden(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	sid := seedTerminalSession(t, fx.d, fx.a)
	open, err := fx.d.CreateReviewRound(db.ReviewRound{ProjectID: fx.a, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = reg.CallRead(context.Background(), "get_review", json.RawMessage(fmt.Sprintf(`{"round_id":%d}`, open)), directBinding(fx.a))
	require.Error(t, err, "an open round is not readable")

	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 1, 1, "q", "sent one")
	_, err = fx.d.Exec(`INSERT INTO review_comments (round_id, body, status) VALUES (?, 'still a draft', 'draft')`, rid)
	require.NoError(t, err)
	got := callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))
	assert.NotContains(t, got, "still a draft")
}

// TestGetReview_TextNamesTheOldSideAndKeepsBlankQuoteLines: an old-side
// comment says so, and a blank line inside a quote stays in it.
func TestGetReview_TextNamesTheOldSideAndKeepsBlankQuoteLines(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	sid := seedTerminalSession(t, fx.d, fx.a)
	rid, err := fx.d.CreateReviewRound(db.ReviewRound{ProjectID: fx.a, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		FolderRoot: "/tmp/acme", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)
	_, err = fx.d.Exec(`INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, body) VALUES (?, 'a.go', 'old', 3, 5, ?, 'why removed')`,
		rid, "x := 1\n\ny := 2\n")
	require.NoError(t, err)
	_, ok, err := fx.d.SendReviewRound(fx.a, rid)
	require.NoError(t, err)
	require.True(t, ok)
	var v reviewView
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))), &v))
	assert.Contains(t, v.Text, "a.go:3-5 (old side)\n")
	assert.Contains(t, v.Text, "> x := 1\n> \n> y := 2\n")
}

func TestGetReview_TextShowsLens(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	rid := seedSentReviewRound(t, fx.d, fx.a, "a.go", 3, 4, "q", "tests missing")
	_, err := fx.d.Exec(`UPDATE review_comments SET lens = 'tests' WHERE round_id = ?`, rid)
	require.NoError(t, err)
	// add a lens-tagged comment and a plain file comment to the sent round before reading
	_, err = fx.d.Exec(`INSERT INTO review_comments (round_id, body, lens, status) VALUES (?, 'why this shape', 'intent', 'sent')`, rid)
	require.NoError(t, err)
	_, err = fx.d.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, body, status) VALUES (?, 'b.go', 1, 1, 'plain', 'sent')`, rid)
	require.NoError(t, err)
	var v reviewView
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "get_review", fmt.Sprintf(`{"round_id":%d}`, rid))), &v))
	assert.Regexp(t, `#\d+ a\.go:3-4 \[tests\]\n`, v.Text)
	assert.Regexp(t, `#\d+ design \[intent\]\n`, v.Text)
	assert.Regexp(t, `#\d+ b\.go:1-1\n`, v.Text)
}
