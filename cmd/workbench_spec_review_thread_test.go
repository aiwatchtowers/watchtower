package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
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

// addFindingCmd runs `spec-review add-finding` with stdin.
func addFindingCmd(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	workbenchSpecReviewAddFindingCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { workbenchSpecReviewAddFindingCmd.SetIn(nil) })
	return runSpecReview(t, append([]string{"add-finding"}, args...)...)
}

// threadRow stores one chat row of the spec review thread contextID.
func threadRow(t *testing.T, database *db.DB, contextID, role, text string) {
	t.Helper()
	var conv int64
	err := database.QueryRow(`SELECT id FROM chat_conversations WHERE context_type = ? AND context_id = ?`,
		db.SpecReviewThreadContextType, contextID).Scan(&conv)
	if errors.Is(err, sql.ErrNoRows) {
		res, err := database.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
			VALUES ('', ?, ?, 0, 0)`, db.SpecReviewThreadContextType, contextID)
		require.NoError(t, err)
		conv, err = res.LastInsertId()
		require.NoError(t, err)
	} else {
		require.NoError(t, err)
	}
	_, err = database.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, 0)`, conv, role, text)
	require.NoError(t, err)
}

const ownerQuoteBlock = `{"kind":"missing","severity":"major","title":"Midnight","text":"The owner wants the mute to end at midnight.",` +
	`"quote":{"source":"thread","text":"end at midnight, not after a day"},"where":null}`

func TestAddFindingCmd_WritesRow(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	ask, err := database.GetOwnerAskByID(id)
	require.NoError(t, err)
	thread := specreview.ThreadContextID(ask.WorkbenchID, id, "ag:0123456789ab")
	threadRow(t, database, thread, "user", "I want it to end at midnight, not after a day")

	block := `{"kind":"decided_alone","severity":"blocker","title":"Behaviour","text":"Twenty-four hours was never agreed.",` +
		`"quote":{"source":"document","text":"Muting lasts twenty-four hours."},` +
		`"where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours."}}`
	out, err := addFindingCmd(t, block, "--ask", itoa(id), "--thread", thread)
	require.NoError(t, err)
	var printed map[string]string
	require.NoError(t, json.Unmarshal([]byte(out), &printed), out)
	key := printed["key"]
	assert.True(t, strings.HasPrefix(key, "tf:"), key)
	assert.Len(t, printed, 1)

	rows, err := database.ListSpecReviewThreadFindings(id)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, key, rows[0].ItemKey)
	assert.Equal(t, thread, rows[0].Thread)
	created, err := time.Parse(time.RFC3339, rows[0].CreatedAt)
	require.NoError(t, err)
	assert.Equal(t, time.UTC, created.Location())
	var f specreview.ThreadFinding
	require.NoError(t, json.Unmarshal([]byte(rows[0].Finding), &f))
	assert.Equal(t, key, f.Key)
	assert.Equal(t, thread, f.Thread)
	assert.Equal(t, specreview.SpeakerAgent, f.Speaker)
	assert.Equal(t, "ch:1", f.Chapter)

	// The owner's own words in the thread: speaker owner.
	out, err = addFindingCmd(t, ownerQuoteBlock, "--ask", itoa(id), "--thread", thread)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &printed), out)
	rows, err = database.ListSpecReviewThreadFindings(id)
	require.NoError(t, err)
	require.Len(t, rows, 2)
	for _, r := range rows {
		if r.ItemKey == printed["key"] {
			require.NoError(t, json.Unmarshal([]byte(r.Finding), &f))
			assert.Equal(t, specreview.SpeakerOwner, f.Speaker)
		}
	}

	// A second press of the same card adds nothing and prints the same key.
	again, err := addFindingCmd(t, ownerQuoteBlock, "--ask", itoa(id), "--thread", thread)
	require.NoError(t, err)
	assert.JSONEq(t, out, again)
	rows, err = database.ListSpecReviewThreadFindings(id)
	require.NoError(t, err)
	assert.Len(t, rows, 2)
}

// TestAddFindingCmd_RefusesForeignThread: a thread of another workbench, or
// one whose root is not the ask's chain root, is refused (Review Focus 5).
func TestAddFindingCmd_RefusesForeignThread(t *testing.T) {
	database, root, _ := specReviewAsk(t)
	first, err := database.GetOwnerAskByID(root)
	require.NoError(t, err)
	next := mustInsertReRoundAsk(t, database, first)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)

	for name, thread := range map[string]string{
		"another workbench":      specreview.ThreadContextID(other, root, "ag:0123456789ab"),
		"not the chain root":     specreview.ThreadContextID(first.WorkbenchID, next, "ag:0123456789ab"),
		"another chain entirely": specreview.ThreadContextID(first.WorkbenchID, root+100, "ag:0123456789ab"),
	} {
		t.Run(name, func(t *testing.T) {
			threadRow(t, database, thread, "user", "I want it to end at midnight, not after a day")
			_, err := addFindingCmd(t, ownerQuoteBlock, "--ask", itoa(next), "--thread", thread)
			requireExit(t, err, 3, "this thread is not part of ask "+itoa(next)+"'s review")
		})
	}
	_, err = addFindingCmd(t, ownerQuoteBlock, "--ask", itoa(next), "--thread", "not-a-thread")
	requireExit(t, err, 2, "")

	// The chain root's thread is accepted from a re-round's ask.
	thread := specreview.ThreadContextID(first.WorkbenchID, root, "ag:0123456789ab")
	threadRow(t, database, thread, "user", "I want it to end at midnight, not after a day")
	_, err = addFindingCmd(t, ownerQuoteBlock, "--ask", itoa(next), "--thread", thread)
	require.NoError(t, err)
	rows, err := database.ListSpecReviewThreadFindings(next)
	require.NoError(t, err)
	assert.Len(t, rows, 1)
}

// TestAddFindingCmd_RefusesInventedQuote: the agent's own words, the owner's
// words in another chain's thread and text found nowhere are all "not
// added: quote not found", and nothing is written (Review Focus 5).
func TestAddFindingCmd_RefusesInventedQuote(t *testing.T) {
	database, id, _ := specReviewAsk(t)
	ask, err := database.GetOwnerAskByID(id)
	require.NoError(t, err)
	thread := specreview.ThreadContextID(ask.WorkbenchID, id, "ag:0123456789ab")
	threadRow(t, database, thread, "user", "why a day?")
	threadRow(t, database, thread, "assistant", "I want it to end at midnight, not after a day")
	// The same words from the owner, but in another chain's thread.
	threadRow(t, database, specreview.ThreadContextID(ask.WorkbenchID, id+100, "ag:0123456789ab"),
		"user", "I want it to end at midnight, not after a day")

	for name, block := range map[string]string{
		"agent's reply":    ownerQuoteBlock,
		"nowhere":          strings.Replace(ownerQuoteBlock, "end at midnight, not after a day", "the owner never said this", 1),
		"document claimed": strings.Replace(ownerQuoteBlock, `"source":"thread"`, `"source":"document"`, 1),
		"bad where": `{"kind":"differs","title":"t","text":"x","quote":{"source":"document","text":"Muting lasts twenty-four hours."},` +
			`"where":{"heading":"Behaviour","quote":"Muting lasts a week."}}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := addFindingCmd(t, block, "--ask", itoa(id), "--thread", thread)
			requireExit(t, err, 3, "not added: quote not found")
		})
	}
	_, err = addFindingCmd(t, `{"kind":"as_agreed"`, "--ask", itoa(id), "--thread", thread)
	requireExit(t, err, 3, "not added: ")
	rows, err := database.ListSpecReviewThreadFindings(id)
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestThreadContextCmd_Blocks(t *testing.T) {
	database, id := boundSpecReviewAsk(t)
	ask, err := database.GetOwnerAskByID(id)
	require.NoError(t, err)
	old := specReviewContextFeed
	specReviewContextFeed = func(*db.DB) func(context.Context, int64) ([]sessionfeed.Entry, error) {
		return func(context.Context, int64) ([]sessionfeed.Entry, error) {
			return []sessionfeed.Entry{{ID: "e1", Kind: sessionfeed.KindOwner, Text: "Mute it for one calendar day"}}, nil
		}
	}
	t.Cleanup(func() { specReviewContextFeed = old })
	var qid int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		qid, _, err = database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: ask.WorkbenchID, SessionID: ask.SessionID,
			Kind: "question", Title: "Scope?", Payload: `{"questions":[{"id":"q1","question":"How long?","options":[{"label":"One day"},{"label":"A week"}]}]}`})
		return err
	}))
	_, err = database.Exec(`UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?`,
		`{"answers":[{"id":"q1","labels":["One day"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`, qid)
	require.NoError(t, err)
	result := `{"summary":"s","brief":"","theses":[],"agreements":[],"decided_alone":[{"key":"da:0123456789ab","text":"Twenty-four hours",` +
		`"note":"","chapter":"ch:1","where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours."}}],` +
		`"blind_spots":[],"checks":[],"resolved":[],"chapters":[],"notes":[],"code_read":false,"dropped":0}`
	_, err = database.Exec(`UPDATE spec_reviews SET status = 'done', result = ? WHERE ask_id = ?`, result, id)
	require.NoError(t, err)

	out, err := runSpecReview(t, "thread-context", "--ask", itoa(id), "--item", "da:0123456789ab")
	require.NoError(t, err)
	for _, block := range []string{"<<<document\n", "<<<item\n", "<<<result\n", "<<<ledger\n", "<<<replies\n", "<<<conversation\n", "<<<asks\n"} {
		assert.Contains(t, out, block)
	}
	assert.Contains(t, out, "Muting lasts twenty-four hours.")
	assert.Contains(t, out, "Mute it for one calendar day")
	assert.Contains(t, out, "How long? → One day")

	_, err = runSpecReview(t, "thread-context", "--ask", itoa(id), "--item", "ag:000000000000")
	requireExit(t, err, 3, "no such item")
}
