package watchmanact

import (
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

// errUnmappable reports a twin reply that cannot be stored as an answer to
// the ask's questions.
var errUnmappable = errors.New("the twin's reply does not fit the ask's questions")

// questionOptions are the options Decide chooses among: those of an ask
// with exactly one single-choice question with options. Several questions,
// a multi-choice question or none with options answer in free text (decide
// v2: one "<question>: <answer>" line per question when there are several).
func questionOptions(p asks.Payload) []string {
	if len(p.Questions) != 1 || p.Questions[0].Multi || len(p.Questions[0].Options) == 0 {
		return nil
	}
	out := make([]string, 0, len(p.Questions[0].Options))
	for _, o := range p.Questions[0].Options {
		out = append(out, o.Label)
	}
	return out
}

// emptyAnswer has every list set, so the stored JSON carries [] (the
// canonical form the Desktop decodes), never null.
func emptyAnswer() asks.Answer {
	return asks.Answer{Answers: []asks.QuestionAnswer{}, Checklist: []asks.CheckAnswer{}, Comments: []asks.Comment{}}
}

// answerFromDecision maps the twin's choice onto a question ask's answer:
// one question takes the option it names, or the choice as its "Other"
// text; several take the "<question>: <answer>" lines of decide v2, each
// mapped back to its question the same way. A reply that leaves a question
// out, names one twice or names none is errUnmappable.
func answerFromDecision(p asks.Payload, dec watchman.Decision) (asks.Answer, error) {
	ans := emptyAnswer()
	choice := strings.TrimSpace(dec.Choice)
	switch len(p.Questions) {
	case 0:
		return asks.Answer{}, fmt.Errorf("%w: the ask has no question", errUnmappable)
	case 1:
		if choice == "" {
			return asks.Answer{}, fmt.Errorf("%w: the choice is empty", errUnmappable)
		}
		ans.Answers = append(ans.Answers, questionAnswer(p.Questions[0], choice))
	default:
		byQuestion, err := splitPerQuestion(p.Questions, choice)
		if err != nil {
			return asks.Answer{}, err
		}
		for _, q := range p.Questions {
			ans.Answers = append(ans.Answers, questionAnswer(q, byQuestion[q.ID]))
		}
	}
	if err := asks.ValidateAnswer(asks.KindQuestion, p, ans); err != nil {
		return asks.Answer{}, fmt.Errorf("%w: %w", errUnmappable, err)
	}
	return ans, nil
}

// questionAnswer is the option of q that text names (several, comma
// separated, on a multi-choice question), else text as the free answer.
func questionAnswer(q asks.Question, text string) asks.QuestionAnswer {
	if l, ok := optionLabel(q, text); ok {
		return asks.QuestionAnswer{ID: q.ID, Labels: []string{l}}
	}
	if q.Multi {
		var labels []string
		for _, part := range strings.Split(text, ",") {
			l, ok := optionLabel(q, part)
			if !ok {
				labels = nil
				break
			}
			labels = append(labels, l)
		}
		if len(labels) > 0 {
			return asks.QuestionAnswer{ID: q.ID, Labels: labels}
		}
	}
	return asks.QuestionAnswer{ID: q.ID, Labels: []string{}, Other: text}
}

// optionLabel is the label of q's option text names (spaces around it
// ignored).
func optionLabel(q asks.Question, text string) (string, bool) {
	text = strings.TrimSpace(text)
	for _, o := range q.Options {
		if strings.TrimSpace(o.Label) == text {
			return o.Label, true
		}
	}
	return "", false
}

// splitPerQuestion reads the "<question>: <answer>" lines into the answer of
// each question by id. A line may start with a list marker; a question's
// text is matched whole (the longest that fits, so one question that
// prefixes another is told apart).
func splitPerQuestion(qs []asks.Question, choice string) (map[string]string, error) {
	out := map[string]string{}
	for i, line := range strings.Split(choice, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "-*•"))
		if line == "" {
			continue
		}
		best := -1
		for k, q := range qs {
			head := strings.TrimSpace(q.Question) + ":"
			if strings.HasPrefix(line, head) && (best < 0 || len(head) > len(strings.TrimSpace(qs[best].Question))+1) {
				best = k
			}
		}
		if best < 0 {
			return nil, fmt.Errorf("%w: line %d names no question", errUnmappable, i+1)
		}
		q := qs[best]
		if _, dup := out[q.ID]; dup {
			return nil, fmt.Errorf("%w: question %q is answered twice", errUnmappable, q.ID)
		}
		text := strings.TrimSpace(strings.TrimPrefix(line, strings.TrimSpace(q.Question)+":"))
		if text == "" {
			return nil, fmt.Errorf("%w: question %q has an empty answer", errUnmappable, q.ID)
		}
		out[q.ID] = text
	}
	for _, q := range qs {
		if _, ok := out[q.ID]; !ok {
			return nil, fmt.Errorf("%w: question %q has no answer", errUnmappable, q.ID)
		}
	}
	return out, nil
}

// textAnswer answers an ask of kind with one text — a park, a hand-back, the
// check answer or a handover choice: every question takes it (its option
// when one has that label, else as "Other"), a check marks every item
// skipped and carries it as the note. A review cannot be answered with a
// text (its verdict is the owner's, or Task 12's), nor a folder suggestion
// (its answer acts on the Mac, the owner's alone): false.
func textAnswer(kind string, p asks.Payload, text string) (asks.Answer, bool) {
	ans := emptyAnswer()
	switch kind {
	case asks.KindReview, db.AskKindFolder:
		return asks.Answer{}, false
	case asks.KindCheck:
		for _, c := range p.Checklist {
			ans.Checklist = append(ans.Checklist, asks.CheckAnswer{ID: c.ID, State: asks.StateSkipped})
		}
		ans.Note = text
	default:
		for _, q := range p.Questions {
			ans.Answers = append(ans.Answers, questionAnswer(q, text))
		}
		if len(p.Questions) == 0 {
			ans.Note = text
		}
	}
	return ans, true
}
