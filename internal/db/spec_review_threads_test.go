package db

import (
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSpecReviewQuestions_OneOpenPerThread(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)

	id, err := d.FileSpecReviewQuestion(askID, "1:7:ag:abc", "ag:abc", "What did you mean?", now)
	require.NoError(t, err)
	_, err = d.FileSpecReviewQuestion(askID, "1:7:ag:abc", "ag:abc", "And this?", now)
	assert.ErrorIs(t, err, ErrQuestionOpen)
	// Another thread has its own slot.
	_, err = d.FileSpecReviewQuestion(askID, "1:7:ag:def", "ag:def", "Other thread", now)
	require.NoError(t, err)

	q, err := d.GetSpecReviewQuestion(id)
	require.NoError(t, err)
	assert.Equal(t, SpecReviewQuestion{ID: id, AskID: askID, Thread: "1:7:ag:abc", ItemKey: "ag:abc",
		Question: "What did you mean?", State: "open", CreatedAt: specReviewTime(now)}, *q)

	// Once the first is closed, the thread may ask again.
	require.NoError(t, d.AnswerSpecReviewQuestion(id, "the cache", now.Add(time.Minute)))
	_, err = d.FileSpecReviewQuestion(askID, "1:7:ag:abc", "ag:abc", "And this?", now)
	require.NoError(t, err)

	_, err = d.GetSpecReviewQuestion(id + 100)
	assert.ErrorIs(t, err, ErrSpecReviewQuestionNotFound)
}

// TestSpecReviewQuestions_AnswerAndCloseRace: an answer and an expiry are both
// conditional updates from 'open'; whichever lands second gets
// ErrQuestionClosed and the row keeps the winner's state.
func TestSpecReviewQuestions_AnswerAndCloseRace(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	now := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)

	answered, err := d.FileSpecReviewQuestion(askID, "1:7:a", "a", "q1", now)
	require.NoError(t, err)
	require.NoError(t, d.AnswerSpecReviewQuestion(answered, "yes", now.Add(time.Minute)))
	assert.ErrorIs(t, d.CloseSpecReviewQuestion(answered, "expired", now.Add(2*time.Minute)), ErrQuestionClosed)
	assert.ErrorIs(t, d.AnswerSpecReviewQuestion(answered, "again", now.Add(2*time.Minute)), ErrQuestionClosed)
	q, err := d.GetSpecReviewQuestion(answered)
	require.NoError(t, err)
	assert.Equal(t, "answered", q.State)
	assert.Equal(t, "yes", q.Answer)
	assert.Equal(t, specReviewTime(now.Add(time.Minute)), q.ClosedAt)

	expired, err := d.FileSpecReviewQuestion(askID, "1:7:b", "b", "q2", now)
	require.NoError(t, err)
	require.NoError(t, d.CloseSpecReviewQuestion(expired, "expired", now.Add(time.Minute)))
	assert.ErrorIs(t, d.AnswerSpecReviewQuestion(expired, "late", now.Add(2*time.Minute)), ErrQuestionClosed)
	q, err = d.GetSpecReviewQuestion(expired)
	require.NoError(t, err)
	assert.Equal(t, "expired", q.State)
	assert.Empty(t, q.Answer)

	gone, err := d.FileSpecReviewQuestion(askID, "1:7:c", "c", "q3", now)
	require.NoError(t, err)
	require.NoError(t, d.CloseSpecReviewQuestion(gone, "gone", now))
	q, err = d.GetSpecReviewQuestion(gone)
	require.NoError(t, err)
	assert.Equal(t, "gone", q.State)

	// Only expired and gone close a question; a missing row is closed too.
	other, err := d.FileSpecReviewQuestion(askID, "1:7:d", "d", "q4", now)
	require.NoError(t, err)
	assert.Error(t, d.CloseSpecReviewQuestion(other, "answered", now))
	assert.Error(t, d.CloseSpecReviewQuestion(other, "open", now))
	assert.ErrorIs(t, d.AnswerSpecReviewQuestion(other+100, "x", now), ErrQuestionClosed)
}

func TestSpecReviewQuestions_OpenToSweep(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newTestSession(t, d, pid)
	bound := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: sql.NullInt64{Int64: sid, Valid: true},
		Kind: "review", Title: "spec", DocPath: "docs/spec.md", DocType: "spec"})
	loose := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "review", Title: "spec", DocPath: "docs/spec.md", DocType: "spec"})
	now := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)

	b, err := d.FileSpecReviewQuestion(bound, "1:a", "a", "q", now)
	require.NoError(t, err)
	l, err := d.FileSpecReviewQuestion(loose, "1:b", "b", "q", now.Add(time.Minute))
	require.NoError(t, err)
	closed, err := d.FileSpecReviewQuestion(bound, "1:c", "c", "q", now)
	require.NoError(t, err)
	require.NoError(t, d.AnswerSpecReviewQuestion(closed, "x", now))

	got, err := d.OpenSpecReviewQuestionsToSweep()
	require.NoError(t, err)
	assert.Equal(t, []SpecReviewQuestionSweep{
		{ID: b, CreatedAt: specReviewTime(now), SessionBound: true},
		{ID: l, CreatedAt: specReviewTime(now.Add(time.Minute)), SessionBound: false},
	}, got)
}

func TestSpecReviewThreadFindings_CascadeWithAsk(t *testing.T) {
	d := openTestDB(t)
	askID := newReviewAsk(t, d)
	keep := newReviewAsk(t, d)
	now := specReviewTime(time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC))

	f := SpecReviewThreadFinding{AskID: askID, ItemKey: "th:1", Thread: "1:7:ag:abc", Finding: `{"title":"x"}`, CreatedAt: now}
	require.NoError(t, d.InsertSpecReviewThreadFinding(f))
	require.NoError(t, d.InsertSpecReviewThreadFinding(SpecReviewThreadFinding{AskID: askID, ItemKey: "th:0", Thread: "t", Finding: "{}", CreatedAt: now}))
	require.NoError(t, d.InsertSpecReviewThreadFinding(SpecReviewThreadFinding{AskID: keep, ItemKey: "th:1", Thread: "t", Finding: "{}", CreatedAt: now}))
	assert.Error(t, d.InsertSpecReviewThreadFinding(f), "a key is added once")
	_, err := d.FileSpecReviewQuestion(askID, "1:7:ag:abc", "ag:abc", "q", time.Now())
	require.NoError(t, err)

	got, err := d.ListSpecReviewThreadFindings(askID)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "th:0", got[0].ItemKey)
	assert.Equal(t, f, got[1])

	_, err = d.Exec(`DELETE FROM owner_asks WHERE id = ?`, askID)
	require.NoError(t, err)
	got, err = d.ListSpecReviewThreadFindings(askID)
	require.NoError(t, err)
	assert.Empty(t, got)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM spec_review_questions WHERE ask_id = ?`, askID).Scan(&n))
	assert.Zero(t, n, "questions go with their ask")
	got, err = d.ListSpecReviewThreadFindings(keep)
	require.NoError(t, err)
	assert.Len(t, got, 1, "another ask's findings stay")
}

// TestOwnerThreadLines_OwnerRowsOnly: only the owner's rows of that thread's
// conversation, on its active branch, in order.
func TestOwnerThreadLines_OwnerRowsOnly(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, SpecReviewThreadContextType, "1:7:ag:abc")
	insertChatMessage(t, d, conv, "user", "is this right?", 1)
	insertChatMessage(t, d, conv, "assistant", "yes", 2)
	insertChatMessage(t, d, conv, "system", "The author did not answer", 3)
	insertChatMessage(t, d, conv, "user", "we keep the cache", 4)
	// Same context id under another type, and another thread: not read.
	other := insertChatConversation(t, d, "code_question", "1:7:ag:abc")
	insertChatMessage(t, d, other, "user", "not mine", 5)
	neighbour := insertChatConversation(t, d, SpecReviewThreadContextType, "1:7:ag:def")
	insertChatMessage(t, d, neighbour, "user", "neighbour", 6)

	got, err := d.OwnerThreadLines("1:7:ag:abc")
	require.NoError(t, err)
	assert.Equal(t, []string{"is this right?", "we keep the cache"}, got)

	// A branched thread keeps only the active branch.
	branched := insertChatConversation(t, d, SpecReviewThreadContextType, "1:7:ag:br")
	root := insertBranchMessage(t, d, branched, 0, "assistant", "root", "t1")
	insertBranchMessage(t, d, branched, root, "user", "abandoned edit", "t2")
	kept := insertBranchMessage(t, d, branched, root, "user", "kept edit", "t3")
	setActiveLeaf(t, d, branched, kept)
	got, err = d.OwnerThreadLines("1:7:ag:br")
	require.NoError(t, err)
	assert.Equal(t, []string{"kept edit"}, got)

	got, err = d.OwnerThreadLines("1:7:none")
	require.NoError(t, err)
	assert.Empty(t, got)
}

// TestDeleteWorkbench_DropsSpecReviewThreads: a workbench delete takes its
// spec review threads (context type and `<workbench>:` prefix, both), not
// another type's conversation with the same prefix, nor another workbench's.
func TestDeleteWorkbench_DropsSpecReviewThreads(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	mine := insertChatConversation(t, d, SpecReviewThreadContextType, fmt.Sprintf("%d:7:ag:abc", pid))
	insertChatMessage(t, d, mine, "user", "thread words", 1)
	longer := insertChatConversation(t, d, SpecReviewThreadContextType, fmt.Sprintf("%d0:7:ag:abc", pid))
	sameprefix := insertChatConversation(t, d, "target", fmt.Sprintf("%d:7:ag:abc", pid))

	require.NoError(t, d.DeleteWorkbench(pid))

	count := func(id int64) int {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, id).Scan(&n))
		return n
	}
	assert.Zero(t, count(mine))
	var msgs int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, mine).Scan(&msgs))
	assert.Zero(t, msgs)
	assert.Equal(t, 1, count(longer), "workbench 10's thread survives workbench 1's delete")
	assert.Equal(t, 1, count(sameprefix), "another context type with the same prefix survives")
}
