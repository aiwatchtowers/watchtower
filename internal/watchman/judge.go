package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// The judge's grades of one twin decision against the owner's (spec
// 2026-11-16-watchman-design §9, ask #1423).
const (
	// GradeSame is the owner's decision.
	GradeSame = "same"
	// GradeAcceptable is a different but reasonable path given the
	// situation: the owner could live with it.
	GradeAcceptable = "acceptable"
	// GradeBad is a decision the owner would have had to undo or correct.
	GradeBad = "bad"
)

// The judge's verdicts on a handoff (spec §9.1, D35, D40): justified when
// the step really needs the owner's own hands, else unjustified.
const (
	HandoffJustified   = "justified"
	HandoffUnjustified = "unjustified"
)

// JudgeInput is one hidden item for the judge. Owner is the owner's choice
// and words, Twin the twin's choice, reasoning and confidence. Questions
// lists the questions of an ask with several, each graded on its own; nil
// means one decision. Handoff is set when the twin handed the item to the
// owner (HandoffOwnerOnly): the judge then rules on the handoff instead of
// grading.
type JudgeInput struct {
	Situation, Owner, Twin string
	Questions              []string
	Handoff                bool
}

// JudgeResult is the judge's reply. For a graded item Grades holds one grade
// per question (one when Questions is empty), in order, and Why the judge's
// reason for each as it gave them; for a handoff Handoff is
// HandoffJustified or HandoffUnjustified and HandoffWhy its reason.
type JudgeResult struct {
	Grades, Why         []string
	Handoff, HandoffWhy string
}

// Judge grades the twin's decision against the owner's real one in the
// situation, or rules on its handoff. The backtest asks it for every item
// but an exact match on a fixed option that was not handed off.
type Judge interface {
	Grade(ctx context.Context, in JudgeInput) (JudgeResult, *digest.Usage, error)
}

// NewLLMJudge judges on the strong tier (prompts.WatchmanJudge).
func NewLLMJudge(gen digest.Generator, store *prompts.Store) Judge {
	return llmJudge{gen: gen, store: store}
}

type llmJudge struct {
	gen   digest.Generator
	store *prompts.Store
}

// Grade asks the model once. For a handoff a reply without a known
// "handoff" verdict is an error; otherwise a reply that is not
// {"grades": [...]} with at least one grade, every one known ("handed"
// included: it is never a grade the judge gives), is an error. Errors carry
// the call's Usage: the backtest cannot score the item, and guessing would
// bend the number. A list of the wrong length is returned as it is; the
// backtest counts a missing grade bad.
func (j llmJudge) Grade(ctx context.Context, in JudgeInput) (JudgeResult, *digest.Usage, error) {
	questions := in.Questions
	if questions == nil {
		questions = []string{}
	}
	handoff := HandoffNone
	if in.Handoff {
		handoff = HandoffOwnerOnly
	}
	// json.Marshal escapes '<' and '>', so no text can close the fence.
	body, err := json.Marshal(struct {
		Situation string   `json:"situation"`
		Owner     string   `json:"owner"`
		Twin      string   `json:"twin"`
		Handoff   string   `json:"handoff"`
		Questions []string `json:"questions"`
	}{in.Situation, in.Owner, in.Twin, handoff, questions})
	if err != nil {
		return JudgeResult{}, nil, fmt.Errorf("watchman judge: encoding the answers: %w", err)
	}
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template (the Decide precedent).
	tmpl, _, _ := prompts.Resolve(j.store, prompts.WatchmanJudge, "")
	raw, usage, _, err := j.gen.Generate(digest.WithSource(ctx, prompts.WatchmanJudge), tmpl,
		"=== DATA ===\n<data>\n"+string(body)+"\n</data>\n", "")
	if err != nil {
		return JudgeResult{}, usage, fmt.Errorf("watchman judge: generating: %w", err)
	}
	var r struct {
		Grades []struct {
			Grade string `json:"grade"`
			Why   string `json:"why"`
		} `json:"grades"`
		Handoff string `json:"handoff"`
		Why     string `json:"why"`
	}
	if json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &r) != nil {
		// A decode error quotes the reply: no model text in a judge error.
		return JudgeResult{}, usage, errors.New("watchman judge: the reply is not a JSON object")
	}
	if in.Handoff {
		switch r.Handoff {
		case HandoffJustified, HandoffUnjustified:
			return JudgeResult{Handoff: r.Handoff, HandoffWhy: strings.TrimSpace(r.Why)}, usage, nil
		}
		// The raw value is model text: never echoed into the error.
		return JudgeResult{}, usage, errors.New("watchman judge: the reply has no known handoff verdict")
	}
	if len(r.Grades) == 0 {
		return JudgeResult{}, usage, errors.New(`watchman judge: the reply has no "grades"`)
	}
	out := JudgeResult{Grades: make([]string, 0, len(r.Grades)), Why: make([]string, 0, len(r.Grades))}
	for _, g := range r.Grades {
		switch g.Grade {
		case GradeSame, GradeAcceptable, GradeBad:
			out.Grades = append(out.Grades, g.Grade)
			out.Why = append(out.Why, strings.TrimSpace(g.Why))
		default:
			// The raw value is model text: never echoed into the error.
			return JudgeResult{}, usage, errors.New("watchman judge: the reply has an unknown grade")
		}
	}
	return out, usage, nil
}
