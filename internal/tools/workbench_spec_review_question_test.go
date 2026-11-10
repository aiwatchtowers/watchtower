package tools

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// questionFixture is an ask filed from session s of workbench a with one
// open thread question on it.
type questionFixture struct {
	workbenchFixture
	session, ask, question int64
}

func newQuestionFixture(t *testing.T) questionFixture {
	t.Helper()
	fx := questionFixture{workbenchFixture: newWorkbenchFixture(t)}
	fx.session = seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(fx.session, 10))
	fx.ask = askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	var err error
	fx.question, err = fx.d.FileSpecReviewQuestion(fx.ask, "thread-1", "ag:1", "Why does a chapter fail?", time.Now())
	require.NoError(t, err)
	return fx
}

func answerArgs(id int64, answer string) string {
	return fmt.Sprintf(`{"question_id":%d,"answer":%q,"reason":"the owner's thread asked"}`, id, answer)
}

func TestAnswerReviewQuestion_WritesAnswer(t *testing.T) {
	fx := newQuestionFixture(t)
	reg := askRegistry(t, fx.d, strconv.FormatInt(fx.session, 10))
	out := mustApply(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, "  A timeout retries it.  "))
	assert.Equal(t, map[string]any{"question_id": float64(fx.question), "state": "answered"}, out)
	q, err := fx.d.GetSpecReviewQuestion(fx.question)
	require.NoError(t, err)
	assert.Equal(t, "answered", q.State)
	assert.Equal(t, "A timeout retries it.", q.Answer)
	assert.NotEmpty(t, q.ClosedAt)
}

func TestAnswerReviewQuestion_RefusesOtherSession(t *testing.T) {
	fx := newQuestionFixture(t)
	other := seedTerminalSession(t, fx.d, fx.a)
	for _, env := range []string{"", "garbage", strconv.FormatInt(other, 10)} {
		reg := askRegistry(t, fx.d, env)
		_, err := proposeIn(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, "Mine."))
		assert.Equal(t, "this question is not for your session", refusal(t, err), "env %q", env)
	}
	q, err := fx.d.GetSpecReviewQuestion(fx.question)
	require.NoError(t, err)
	assert.Equal(t, "open", q.State)
}

// Another workbench's question and a missing id read alike: not found.
func TestAnswerReviewQuestion_RefusesUnknownAndOtherWorkbench(t *testing.T) {
	fx := newQuestionFixture(t)
	theirs := seedTerminalSession(t, fx.d, fx.b)
	reg := askRegistry(t, fx.d, strconv.FormatInt(theirs, 10))
	for _, id := range []int64{fx.question, 999999} {
		_, err := proposeIn(t, reg, fx.b, "answer_review_question", answerArgs(id, "Mine."))
		require.ErrorIs(t, err, db.ErrSpecReviewQuestionNotFound)
		assert.Equal(t, fmt.Sprintf("question %d not found", id), refusal(t, err))
	}
}

func TestAnswerReviewQuestion_RefusesClosed(t *testing.T) {
	fx := newQuestionFixture(t)
	require.NoError(t, fx.d.CloseSpecReviewQuestion(fx.question, "expired", time.Now()))
	reg := askRegistry(t, fx.d, strconv.FormatInt(fx.session, 10))
	_, err := proposeIn(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, "Late."))
	assert.Equal(t, "the question is closed", refusal(t, err))
	q, err := fx.d.GetSpecReviewQuestion(fx.question)
	require.NoError(t, err)
	assert.Equal(t, "expired", q.State)
	assert.Empty(t, q.Answer)
}

func TestAnswerReviewQuestion_RefusesTooLong(t *testing.T) {
	fx := newQuestionFixture(t)
	reg := askRegistry(t, fx.d, strconv.FormatInt(fx.session, 10))
	_, err := proposeIn(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, strings.Repeat("я", 2001)))
	assert.Equal(t, "answer: at most 2000 characters", refusal(t, err))
	_, err = proposeIn(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, "   "))
	assert.Equal(t, "answer: required", refusal(t, err))
	mustApply(t, reg, fx.a, "answer_review_question", answerArgs(fx.question, strings.Repeat("я", 2000)))
}
