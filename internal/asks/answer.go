package asks

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Review verdicts.
const (
	VerdictApproved = "approved"
	VerdictChanges  = "changes"
)

// Check item states. An item the owner left unmarked is sent as skipped.
const (
	StateOK      = "ok"
	StateBroken  = "broken"
	StateSkipped = "skipped"
)

// Answer is owner_asks.answer: written by the Desktop, read by get_ask. The
// fields of every type here are declared in key order, so json.Marshal emits
// the canonical form (sorted keys) that testdata/answers pins and the Swift
// encoder reproduces byte for byte. Keep them sorted.
type Answer struct {
	Answers   []QuestionAnswer `json:"answers"`
	Checklist []CheckAnswer    `json:"checklist"`
	Comments  []Comment        `json:"comments"`
	Note      string           `json:"note"`
	Verdict   string           `json:"verdict"`
}

// QuestionAnswer answers one question: chosen labels and/or a free answer.
type QuestionAnswer struct {
	ID     string   `json:"id"`
	Labels []string `json:"labels"`
	Other  string   `json:"other"`
}

// CheckAnswer marks one check item.
type CheckAnswer struct {
	ID    string `json:"id"`
	Note  string `json:"note"`
	State string `json:"state"`
}

// Comment is a review comment anchored on the doc snapshot.
type Comment struct {
	Body    string `json:"body"`
	Heading string `json:"heading"`
	Prefix  string `json:"prefix"`
	Quote   string `json:"quote"`
	Suffix  string `json:"suffix"`
}

// ParseAnswer decodes a stored answer and checks what holds for any ask:
// a known verdict, known item states, a note on a broken item, the note
// bound. Missing lists come back empty. Whether the answer fits its ask is
// ValidateAnswer's.
func ParseAnswer(raw []byte) (Answer, error) {
	var a Answer
	if err := json.Unmarshal(raw, &a); err != nil {
		return Answer{}, fmt.Errorf("answer: %w", err)
	}
	if a.Answers == nil {
		a.Answers = []QuestionAnswer{}
	}
	for i := range a.Answers {
		if a.Answers[i].Labels == nil {
			a.Answers[i].Labels = []string{}
		}
	}
	if a.Checklist == nil {
		a.Checklist = []CheckAnswer{}
	}
	if a.Comments == nil {
		a.Comments = []Comment{}
	}
	switch a.Verdict {
	case "", VerdictApproved, VerdictChanges:
	default:
		return Answer{}, fmt.Errorf("verdict: must be approved or changes")
	}
	for i, c := range a.Checklist {
		switch c.State {
		case StateOK, StateSkipped:
		case StateBroken:
			if strings.TrimSpace(c.Note) == "" {
				return Answer{}, fmt.Errorf("checklist[%d].note: required when broken", i)
			}
		default:
			return Answer{}, fmt.Errorf("checklist[%d].state: must be ok, broken or skipped", i)
		}
	}
	if utf8.RuneCountInString(a.Note) > 4000 {
		return Answer{}, fmt.Errorf("note: at most 4000 characters")
	}
	return a, nil
}

// ValidateAnswer checks a parsed answer against the ask it answers: a
// verdict exactly on a review, comments only there, one non-empty answer
// per question with known labels, and every check item marked once.
func ValidateAnswer(kind string, p Payload, a Answer) error {
	switch {
	case kind == KindReview && a.Verdict == "":
		return fmt.Errorf("verdict: required for a review")
	case kind != KindReview && a.Verdict != "":
		return fmt.Errorf("verdict: only a review has a verdict")
	case kind != KindReview && len(a.Comments) > 0:
		return fmt.Errorf("comments: only a review has comments")
	}
	for i, c := range a.Comments {
		if strings.TrimSpace(c.Body) == "" {
			return fmt.Errorf("comments[%d].body: required", i)
		}
	}
	if err := validateQuestionAnswers(p.Questions, a.Answers); err != nil {
		return err
	}
	return validateCheckAnswers(p.Checklist, a.Checklist)
}

func validateQuestionAnswers(questions []Question, answers []QuestionAnswer) error {
	byID := make(map[string]Question, len(questions))
	for _, q := range questions {
		byID[q.ID] = q
	}
	seen := map[string]bool{}
	for i, ans := range answers {
		field := fmt.Sprintf("answers[%d]", i)
		q, ok := byID[ans.ID]
		if !ok {
			return fmt.Errorf("%s.id: no question %q", field, ans.ID)
		}
		if seen[ans.ID] {
			return fmt.Errorf("%s.id: question %q answered twice", field, ans.ID)
		}
		seen[ans.ID] = true
		if len(ans.Labels) == 0 && strings.TrimSpace(ans.Other) == "" {
			return fmt.Errorf("%s: no label and no other answer", field)
		}
		if !q.Multi && len(ans.Labels) > 1 {
			return fmt.Errorf("%s.labels: question %q takes one label", field, ans.ID)
		}
		for _, label := range ans.Labels {
			if !hasLabel(q, label) {
				return fmt.Errorf("%s.labels: question %q has no option %q", field, ans.ID, label)
			}
		}
	}
	for _, q := range questions {
		if !seen[q.ID] {
			return fmt.Errorf("answers: question %q has no answer", q.ID)
		}
	}
	return nil
}

func hasLabel(q Question, label string) bool {
	for _, o := range q.Options {
		if o.Label == label {
			return true
		}
	}
	return false
}

func validateCheckAnswers(items []ChecklistItem, marks []CheckAnswer) error {
	known := make(map[string]bool, len(items))
	for _, c := range items {
		known[c.ID] = true
	}
	seen := map[string]bool{}
	for i, m := range marks {
		field := fmt.Sprintf("checklist[%d]", i)
		if !known[m.ID] {
			return fmt.Errorf("%s.id: no check item %q", field, m.ID)
		}
		if seen[m.ID] {
			return fmt.Errorf("%s.id: item %q marked twice", field, m.ID)
		}
		seen[m.ID] = true
	}
	for _, c := range items {
		if !seen[c.ID] {
			return fmt.Errorf("checklist: item %q has no state", c.ID)
		}
	}
	return nil
}
