// Package asks owns the shape of a workbench owner ask (spec 2026-10-03,
// Part 3): the ask_owner input validation, the stored payload and answer
// types, the readable answer rendering get_ask returns and the delivery line
// the Desktop types into the session. It does no I/O; the doc_path file
// check, target scope and the open-ask cap are the tool's.
package asks

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The three ask kinds.
const (
	KindReview   = "review"
	KindCheck    = "check"
	KindQuestion = "question"
)

const (
	// MaxOpenPerWorkbench caps the open asks of one workbench.
	MaxOpenPerWorkbench = 30
	// MaxSnapshotBytes caps a review's document, read into doc_snapshot.
	MaxSnapshotBytes = 2 << 20
)

// Focus points the owner at what to look at; heading and quote anchor it in
// a review's document.
type Focus struct {
	Text    string `json:"text"`
	Heading string `json:"heading,omitempty"`
	Quote   string `json:"quote,omitempty"`
}

// Option is one answer of a question.
type Option struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
	Recommended bool   `json:"recommended,omitempty"`
}

// Question has the chat question card's shape (spec 2026-10-02) and bounds;
// the shared testdata/cards fixtures pin it to the Swift ChatQuestionCard.
type Question struct {
	ID       string   `json:"id,omitempty"`
	Question string   `json:"question"`
	Multi    bool     `json:"multi,omitempty"`
	Options  []Option `json:"options"`
}

// ChecklistItem is one step of a check ask.
type ChecklistItem struct {
	ID   string `json:"id,omitempty"`
	Text string `json:"text"`
	Hint string `json:"hint,omitempty"`
}

// Input is the ask_owner request the package checks. Target and reason are
// the tool's own arguments.
type Input struct {
	Kind          string          `json:"kind"`
	Title         string          `json:"title"`
	Summary       string          `json:"summary,omitempty"`
	Changes       string          `json:"changes,omitempty"`
	Focus         []Focus         `json:"focus,omitempty"`
	Questions     []Question      `json:"questions,omitempty"`
	Checklist     []ChecklistItem `json:"checklist,omitempty"`
	DocPath       string          `json:"doc_path,omitempty"`
	PreviousAskID int64           `json:"previous_ask_id,omitempty"`
}

// Payload is what owner_asks.payload stores: the validated lists, text
// trimmed and every id filled in. The lists are never nil, so the JSON
// always holds all three keys.
type Payload struct {
	Focus     []Focus         `json:"focus"`
	Questions []Question      `json:"questions"`
	Checklist []ChecklistItem `json:"checklist"`
}

// Validate checks an ask_owner input against the Part 3 rules and returns
// its payload. The first violation is the error, as `field: reason`. The
// title is checked trimmed; storing it trimmed is the caller's.
func Validate(in Input) (Payload, error) {
	var p Payload
	switch in.Kind {
	case KindReview, KindCheck, KindQuestion:
	default:
		return p, fmt.Errorf("kind: must be review, check or question")
	}
	if err := firstErr(
		checkText("title", in.Title, true, 120),
		checkText("summary", in.Summary, false, 2000),
		checkText("changes", in.Changes, false, 1000),
	); err != nil {
		return p, err
	}
	if strings.TrimSpace(in.Changes) != "" && in.PreviousAskID == 0 {
		return p, fmt.Errorf("changes: only with previous_ask_id")
	}
	var err error
	if p.Focus, err = validateFocus(in.Kind, in.Focus); err != nil {
		return p, err
	}
	if p.Questions, err = validateQuestions(in.Kind, in.Questions); err != nil {
		return p, err
	}
	if p.Checklist, err = validateChecklist(in.Kind, in.Checklist); err != nil {
		return p, err
	}
	switch hasDoc := strings.TrimSpace(in.DocPath) != ""; {
	case in.Kind == KindReview && !hasDoc:
		return p, fmt.Errorf("doc_path: required for a review")
	case in.Kind != KindReview && hasDoc:
		return p, fmt.Errorf("doc_path: only a review has a document")
	}
	return p, nil
}

func validateFocus(kind string, focus []Focus) ([]Focus, error) {
	if len(focus) > 5 {
		return nil, fmt.Errorf("focus: at most 5 items")
	}
	out := make([]Focus, 0, len(focus))
	for i, f := range focus {
		field := fmt.Sprintf("focus[%d]", i)
		f = Focus{Text: strings.TrimSpace(f.Text), Heading: strings.TrimSpace(f.Heading), Quote: strings.TrimSpace(f.Quote)}
		if err := firstErr(
			checkText(field+".text", f.Text, true, 300),
			checkText(field+".heading", f.Heading, false, 200),
			checkText(field+".quote", f.Quote, false, 300),
		); err != nil {
			return nil, err
		}
		if kind != KindReview {
			if f.Heading != "" {
				return nil, fmt.Errorf("%s.heading: only a review anchors focus in a document", field)
			}
			if f.Quote != "" {
				return nil, fmt.Errorf("%s.quote: only a review anchors focus in a document", field)
			}
		}
		out = append(out, f)
	}
	return out, nil
}

// validateQuestions mirrors the Swift ChatQuestionParser: question and label
// trimmed and non-empty, an empty id is the 1-based position, ids unique and
// labels unique within a question.
func validateQuestions(kind string, questions []Question) ([]Question, error) {
	if len(questions) > 4 {
		return nil, fmt.Errorf("questions: at most 4")
	}
	if kind == KindQuestion && len(questions) == 0 {
		return nil, fmt.Errorf("questions: a question ask needs 1 to 4")
	}
	out := make([]Question, 0, len(questions))
	ids := map[string]bool{}
	for i, q := range questions {
		field := fmt.Sprintf("questions[%d]", i)
		q.ID = defaultID(q.ID, i)
		if ids[q.ID] {
			return nil, fmt.Errorf("%s.id: duplicate id %q", field, q.ID)
		}
		ids[q.ID] = true
		q.Question = strings.TrimSpace(q.Question)
		if q.Question == "" {
			return nil, fmt.Errorf("%s.question: required", field)
		}
		if len(q.Options) < 2 || len(q.Options) > 4 {
			return nil, fmt.Errorf("%s.options: 2 to 4 required", field)
		}
		options := make([]Option, 0, len(q.Options))
		labels := map[string]bool{}
		for j, o := range q.Options {
			ofield := fmt.Sprintf("%s.options[%d]", field, j)
			o.Label = strings.TrimSpace(o.Label)
			o.Description = strings.TrimSpace(o.Description)
			if err := firstErr(
				checkText(ofield+".label", o.Label, true, 80),
				checkText(ofield+".description", o.Description, false, 300),
			); err != nil {
				return nil, err
			}
			if labels[o.Label] {
				return nil, fmt.Errorf("%s.label: duplicate label %q", ofield, o.Label)
			}
			labels[o.Label] = true
			options = append(options, o)
		}
		q.Options = options
		out = append(out, q)
	}
	return out, nil
}

func validateChecklist(kind string, items []ChecklistItem) ([]ChecklistItem, error) {
	if kind != KindCheck {
		if len(items) > 0 {
			return nil, fmt.Errorf("checklist: only a check ask has a checklist")
		}
		return []ChecklistItem{}, nil
	}
	if len(items) == 0 || len(items) > 30 {
		return nil, fmt.Errorf("checklist: 1 to 30 items required")
	}
	out := make([]ChecklistItem, 0, len(items))
	ids := map[string]bool{}
	for i, c := range items {
		field := fmt.Sprintf("checklist[%d]", i)
		c.ID = defaultID(c.ID, i)
		if ids[c.ID] {
			return nil, fmt.Errorf("%s.id: duplicate id %q", field, c.ID)
		}
		ids[c.ID] = true
		c.Text = strings.TrimSpace(c.Text)
		c.Hint = strings.TrimSpace(c.Hint)
		if err := firstErr(
			checkText(field+".text", c.Text, true, 300),
			checkText(field+".hint", c.Hint, false, 300),
		); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

// defaultID is an item's id: its own, or its 1-based position when empty.
func defaultID(id string, index int) string {
	if id == "" {
		return strconv.Itoa(index + 1)
	}
	return id
}

// checkText bounds s, trimmed, to at most limit runes, and to at least one
// when required.
func checkText(field, s string, required bool, limit int) error {
	n := utf8.RuneCountInString(strings.TrimSpace(s))
	if required && n == 0 {
		return fmt.Errorf("%s: required", field)
	}
	if n > limit {
		return fmt.Errorf("%s: at most %d characters", field, limit)
	}
	return nil
}

// firstErr returns the first non-nil error, or nil.
func firstErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}
