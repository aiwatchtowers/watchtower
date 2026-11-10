package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/sqlcipher"
)

// Spec review threads (00178, spec 2026-11-08 §3): the thread agent's
// questions to the author and the findings the owner added from a thread. Go
// is the only writer of both tables; the Desktop only reads them.

// SpecReviewThreadContextType is the chat_conversations.context_type of a
// spec review thread. Such a conversation never leaves its card: every chat
// reader outside it filters this type out (the code-question guards).
const SpecReviewThreadContextType = "spec_review_thread"

// ErrQuestionClosed refuses a state change on a question that is no longer
// open (or does not exist): an answer and an expiry cannot both land.
var ErrQuestionClosed = errors.New("the question is closed")

// ErrQuestionOpen refuses a new question on a thread that already has one open.
var ErrQuestionOpen = errors.New("the thread already has an open question")

// ErrSpecReviewQuestionNotFound is returned when no question has the id.
var ErrSpecReviewQuestionNotFound = errors.New("spec review question not found")

// SpecReviewQuestion is one spec_review_questions row.
type SpecReviewQuestion struct {
	ID, AskID                                                     int64
	Thread, ItemKey, Question, Answer, State, CreatedAt, ClosedAt string
}

// SpecReviewQuestionSweep is one open question for the daemon's sweep;
// SessionBound = the ask still has a session (owner_asks.session_id set).
type SpecReviewQuestionSweep struct {
	ID           int64
	CreatedAt    string
	SessionBound bool
}

// SpecReviewThreadFinding is one finding the owner added from a thread;
// Finding is its JSON.
type SpecReviewThreadFinding struct {
	AskID                               int64
	ItemKey, Thread, Finding, CreatedAt string
}

// FileSpecReviewQuestion files an open question on thread and returns its id;
// a thread with an open question already refuses with ErrQuestionOpen.
func (db *DB) FileSpecReviewQuestion(askID int64, thread, itemKey, question string, now time.Time) (int64, error) {
	res, err := db.Exec(`INSERT INTO spec_review_questions (ask_id, thread, item_key, question, created_at)
		VALUES (?, ?, ?, ?, ?)`, askID, thread, itemKey, question, specReviewTime(now))
	if err != nil {
		var se sqlcipher.Error
		if errors.As(err, &se) && se.ExtendedCode == sqlcipher.ErrConstraintUnique {
			return 0, ErrQuestionOpen
		}
		return 0, fmt.Errorf("filing spec review question on ask %d: %w", askID, err)
	}
	return res.LastInsertId()
}

// AnswerSpecReviewQuestion records the author's answer on an open question;
// a closed or missing one refuses with ErrQuestionClosed.
func (db *DB) AnswerSpecReviewQuestion(id int64, answer string, now time.Time) error {
	res, err := db.Exec(`UPDATE spec_review_questions SET state = 'answered', answer = ?, closed_at = ?
		WHERE id = ? AND state = 'open'`, answer, specReviewTime(now), id)
	if err != nil {
		return fmt.Errorf("answering spec review question %d: %w", id, err)
	}
	return questionChanged(res, id)
}

// CloseSpecReviewQuestion closes an open question as 'expired' or 'gone'; a
// closed or missing one refuses with ErrQuestionClosed.
func (db *DB) CloseSpecReviewQuestion(id int64, state string, now time.Time) error {
	if state != "expired" && state != "gone" {
		return fmt.Errorf("closing spec review question %d: state %q is not expired or gone", id, state)
	}
	res, err := db.Exec(`UPDATE spec_review_questions SET state = ?, closed_at = ?
		WHERE id = ? AND state = 'open'`, state, specReviewTime(now), id)
	if err != nil {
		return fmt.Errorf("closing spec review question %d: %w", id, err)
	}
	return questionChanged(res, id)
}

func questionChanged(res sql.Result, id int64) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("spec review question %d: %w", id, err)
	}
	if n == 0 {
		return ErrQuestionClosed
	}
	return nil
}

// GetSpecReviewQuestion reads one question; a missing id is
// ErrSpecReviewQuestionNotFound.
func (db *DB) GetSpecReviewQuestion(id int64) (*SpecReviewQuestion, error) {
	var q SpecReviewQuestion
	err := db.QueryRow(`SELECT id, ask_id, thread, item_key, question, answer, state, created_at, closed_at
		FROM spec_review_questions WHERE id = ?`, id).Scan(&q.ID, &q.AskID, &q.Thread, &q.ItemKey,
		&q.Question, &q.Answer, &q.State, &q.CreatedAt, &q.ClosedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSpecReviewQuestionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading spec review question %d: %w", id, err)
	}
	return &q, nil
}

// OpenSpecReviewQuestionsToSweep lists the open questions, oldest first, for
// the daemon's sweep (expired after the author timeout, gone without a session).
func (db *DB) OpenSpecReviewQuestionsToSweep() ([]SpecReviewQuestionSweep, error) {
	rows, err := db.Query(`SELECT q.id, q.created_at, a.session_id IS NOT NULL
		FROM spec_review_questions q JOIN owner_asks a ON a.id = q.ask_id
		WHERE q.state = 'open' ORDER BY q.id`)
	if err != nil {
		return nil, fmt.Errorf("listing open spec review questions: %w", err)
	}
	defer rows.Close()
	var out []SpecReviewQuestionSweep
	for rows.Next() {
		var s SpecReviewQuestionSweep
		if err := rows.Scan(&s.ID, &s.CreatedAt, &s.SessionBound); err != nil {
			return nil, fmt.Errorf("scanning open spec review question: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// InsertSpecReviewThreadFinding stores a finding the owner added from a
// thread; a key already added to the ask fails (primary key).
func (db *DB) InsertSpecReviewThreadFinding(f SpecReviewThreadFinding) error {
	if _, err := db.Exec(`INSERT INTO spec_review_thread_findings (ask_id, item_key, thread, finding, created_at)
		VALUES (?, ?, ?, ?, ?)`, f.AskID, f.ItemKey, f.Thread, f.Finding, f.CreatedAt); err != nil {
		return fmt.Errorf("adding thread finding %s to ask %d: %w", f.ItemKey, f.AskID, err)
	}
	return nil
}

// ListSpecReviewThreadFindings lists an ask's thread findings, by key.
func (db *DB) ListSpecReviewThreadFindings(askID int64) ([]SpecReviewThreadFinding, error) {
	rows, err := db.Query(`SELECT ask_id, item_key, thread, finding, created_at
		FROM spec_review_thread_findings WHERE ask_id = ? ORDER BY item_key`, askID)
	if err != nil {
		return nil, fmt.Errorf("listing thread findings of ask %d: %w", askID, err)
	}
	defer rows.Close()
	var out []SpecReviewThreadFinding
	for rows.Next() {
		var f SpecReviewThreadFinding
		if err := rows.Scan(&f.AskID, &f.ItemKey, &f.Thread, &f.Finding, &f.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning thread finding: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// OwnerThreadLines returns the texts of the owner's rows (role 'user') of the
// spec review thread contextID, on its active branch, in order: the owner's
// words a thread's proposed finding may quote.
func (db *DB) OwnerThreadLines(contextID string) ([]string, error) {
	rows, err := db.Query(activeBranchCTE+`SELECT m.text
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.context_type = ? AND c.context_id = ? AND m.role = 'user' AND `+onActiveBranch+`
		ORDER BY m.id`, SpecReviewThreadContextType, contextID)
	if err != nil {
		return nil, fmt.Errorf("reading owner lines of thread %s: %w", contextID, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, fmt.Errorf("scanning owner thread line: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
