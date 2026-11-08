package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// maxQuestionAnswerRunes caps the author's answer to a thread question (spec
// 2026-11-08 "Asking the author").
const maxQuestionAnswerRunes = 2000

type answerReviewQuestionArgs struct {
	QuestionID int64  `json:"question_id" jsonschema:"the id from the line Owner's thread on spec review ask #N asks you: …"`
	Answer     string `json:"answer" jsonschema:"your answer to that one question (1-2000 characters)"`
	Reason     string `json:"reason" jsonschema:"one sentence: why you answer"`
}

func errQuestionNotFound(id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("question %d not found", id), Err: db.ErrSpecReviewQuestionNotFound}
}

// NewAnswerReviewQuestion is answer_review_question: the author answers the
// one question an owner's spec review thread asked its session. It writes only
// the answer of an open question of the calling session's own ask; applied
// immediately and audited.
func NewAnswerReviewQuestion(sessionEnv func() string) *Tool {
	return &Tool{
		Name: "answer_review_question",
		Description: "Answer the question the owner's spec review thread asked you (the line \"Owner's thread on spec " +
			"review ask #N asks you: … — answer with answer_review_question <id>\"). Answer only that question, then " +
			"carry on. Applied immediately.",
		InputSchema: mustSchema[answerReviewQuestionArgs]("answer_review_question"),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a answerReviewQuestionArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if _, err := boundedText("answer", a.Answer, maxQuestionAnswerRunes); err != nil {
				return err
			}
			_, err := boundedText("reason", a.Reason, maxReasonRunes)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a answerReviewQuestionArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return questionOfSession(ctx, d, b, a.QuestionID, sessionEnv)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a answerReviewQuestionArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding answer_review_question args: %w", err)
			}
			if err := questionOfSession(ctx, d, call.Binding, a.QuestionID, sessionEnv); err != nil {
				return nil, err
			}
			answer, err := boundedText("answer", a.Answer, maxQuestionAnswerRunes)
			if err != nil {
				return nil, err
			}
			if err := d.AnswerSpecReviewQuestion(a.QuestionID, answer, time.Now()); err != nil {
				if errors.Is(err, db.ErrQuestionClosed) {
					return nil, &ValidationError{Msg: db.ErrQuestionClosed.Error(), Err: err}
				}
				return nil, fmt.Errorf("answering question %d: %w", a.QuestionID, err)
			}
			return map[string]any{"question_id": a.QuestionID, "state": "answered"}, nil
		},
	}
}

// questionOfSession passes when question id belongs to an ask of the bound
// workbench filed from the calling terminal session and is still open. A
// missing id and another workbench's question read alike as not found.
func questionOfSession(ctx context.Context, d *db.DB, b Binding, id int64, sessionEnv func() string) error {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return err
	}
	q, err := d.GetSpecReviewQuestion(id)
	if errors.Is(err, db.ErrSpecReviewQuestionNotFound) {
		return errQuestionNotFound(id)
	}
	if err != nil {
		return fmt.Errorf("reading question %d: %w", id, err)
	}
	ask, err := d.GetOwnerAsk(p.ID, q.AskID)
	if errors.Is(err, db.ErrAskNotFound) {
		return errQuestionNotFound(id)
	}
	if err != nil {
		return fmt.Errorf("reading ask %d of question %d: %w", q.AskID, id, err)
	}
	session, err := terminalSessionOf(d, p.ID, sessionEnv)
	if err != nil {
		return fmt.Errorf("resolving the calling session: %w", err)
	}
	if !session.Valid || !ask.SessionID.Valid || ask.SessionID.Int64 != session.Int64 {
		return &ValidationError{Msg: "this question is not for your session"}
	}
	if q.State != "open" {
		return &ValidationError{Msg: db.ErrQuestionClosed.Error(), Err: db.ErrQuestionClosed}
	}
	return nil
}
