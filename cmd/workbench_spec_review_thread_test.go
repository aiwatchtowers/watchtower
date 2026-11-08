package cmd

import (
	"database/sql"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

// questionCmd runs `spec-review question` with stdin.
func questionCmd(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	workbenchSpecReviewQuestionCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { workbenchSpecReviewQuestionCmd.SetIn(nil) })
	return runSpecReview(t, append([]string{"question"}, args...)...)
}

// boundSpecReviewAsk is specReviewAsk with the ask bound to a session.
func boundSpecReviewAsk(t *testing.T) (*db.DB, int64) {
	t.Helper()
	database, id, repo := specReviewAsk(t)
	ask, err := database.GetOwnerAskByID(id)
	require.NoError(t, err)
	sid := reviewSession(t, database, ask.WorkbenchID, repo)
	_, err = database.Exec(`UPDATE owner_asks SET session_id = ? WHERE id = ?`, sid, id)
	require.NoError(t, err)
	return database, id
}

func requireExit(t *testing.T, err error, code int, text string) {
	t.Helper()
	var ec *exitCodeError
	require.True(t, errors.As(err, &ec), "%v", err)
	assert.Equal(t, code, ec.code)
	assert.Contains(t, err.Error(), text)
}

func TestSpecReviewQuestionCmd_FilesAndPrintsID(t *testing.T) {
	database, root := boundSpecReviewAsk(t)
	first, err := database.GetOwnerAskByID(root)
	require.NoError(t, err)
	// A re-round: the thread is keyed by the chain's root, not by this ask.
	next := mustInsertReRoundAsk(t, database, first)
	_, err = database.Exec(`UPDATE owner_asks SET session_id = (SELECT session_id FROM owner_asks WHERE id = ?) WHERE id = ?`, root, next)
	require.NoError(t, err)

	out, err := questionCmd(t, "  What does a day mean here?\n", "--ask", itoa(next), "--item", "ag:0123456789ab")
	require.NoError(t, err)
	id, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	require.NoError(t, err, out)

	q, err := database.GetSpecReviewQuestion(id)
	require.NoError(t, err)
	assert.Equal(t, next, q.AskID)
	assert.Equal(t, "ag:0123456789ab", q.ItemKey)
	assert.Equal(t, "What does a day mean here?", q.Question, "trimmed")
	assert.Equal(t, "open", q.State)
	assert.Equal(t, specreview.ThreadContextID(first.WorkbenchID, root, "ag:0123456789ab"), q.Thread)
	created, err := time.Parse(time.RFC3339, q.CreatedAt)
	require.NoError(t, err, q.CreatedAt)
	assert.Equal(t, time.UTC, created.Location())
}

func mustInsertReRoundAsk(t *testing.T, database *db.DB, prev *db.OwnerAsk) int64 {
	t.Helper()
	var id int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		id, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: prev.WorkbenchID, Kind: "review", Title: "Spec",
			DocPath: prev.DocPath, DocSnapshot: specReviewDoc, DocType: "spec",
			PreviousAskID: sql.NullInt64{Int64: prev.ID, Valid: true}})
		return err
	}))
	return id
}

func TestSpecReviewQuestionCmd_RefusesSecondOpen(t *testing.T) {
	database, id := boundSpecReviewAsk(t)
	_, err := questionCmd(t, "first?", "--ask", itoa(id), "--item", "ag:0123456789ab")
	require.NoError(t, err)

	_, err = questionCmd(t, "second?", "--ask", itoa(id), "--item", "ag:0123456789ab")
	requireExit(t, err, 3, "a question is already open in this thread")

	// Another item is another thread.
	_, err = questionCmd(t, "other?", "--ask", itoa(id), "--item", "ag:ba9876543210")
	require.NoError(t, err)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM spec_review_questions WHERE state = 'open'`).Scan(&n))
	assert.Equal(t, 2, n)
}

func TestSpecReviewQuestionCmd_RefusesNoSession(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	_, err := questionCmd(t, "why?", "--ask", itoa(id), "--item", "ag:0123456789ab")
	requireExit(t, err, 3, "ask "+itoa(id)+" has no session")
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM spec_review_questions`).Scan(&n))
	assert.Zero(t, n)
}

func TestSpecReviewQuestionCmd_UsageErrors(t *testing.T) {
	_, id := boundSpecReviewAsk(t)
	for name, c := range map[string]struct {
		stdin string
		args  []string
	}{
		"empty question":  {"  \n", []string{"--ask", itoa(id), "--item", "ag:0123456789ab"}},
		"too long":        {strings.Repeat("я", maxQuestionRunes+1), []string{"--ask", itoa(id), "--item", "ag:0123456789ab"}},
		"no item":         {"why?", []string{"--ask", itoa(id)}},
		"no ask":          {"why?", []string{"--item", "ag:0123456789ab"}},
		"close and ask":   {"", []string{"--close", "1", "--reason", "gone", "--ask", itoa(id)}},
		"bad reason":      {"", []string{"--close", "1", "--reason", "expired"}},
		"close no reason": {"", []string{"--close", "1"}},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := questionCmd(t, c.stdin, c.args...)
			requireExit(t, err, 2, "")
		})
	}
	// Exactly the limit is accepted.
	_, err := questionCmd(t, strings.Repeat("я", maxQuestionRunes), "--ask", itoa(id), "--item", "ag:0123456789ab")
	require.NoError(t, err)
}

func TestSpecReviewQuestionCmd_CloseGone(t *testing.T) {
	database, id := boundSpecReviewAsk(t)
	out, err := questionCmd(t, "why?", "--ask", itoa(id), "--item", "ag:0123456789ab")
	require.NoError(t, err)
	qid := strings.TrimSpace(out)

	_, err = questionCmd(t, "", "--close", qid, "--reason", "gone")
	require.NoError(t, err)
	n, err := strconv.ParseInt(qid, 10, 64)
	require.NoError(t, err)
	q, err := database.GetSpecReviewQuestion(n)
	require.NoError(t, err)
	assert.Equal(t, "gone", q.State)
	assert.NotEmpty(t, q.ClosedAt)

	_, err = questionCmd(t, "", "--close", qid, "--reason", "gone")
	requireExit(t, err, 3, "the question is closed")
	_, err = questionCmd(t, "", "--close", "999999", "--reason", "gone")
	requireExit(t, err, 3, "the question is closed")
}
