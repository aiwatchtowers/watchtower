package watchman

import (
	"context"
	"encoding/json"
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

// JudgeInput is one hidden item for the judge. Owner is the owner's choice
// and words, Twin the twin's choice, reasoning and confidence. Questions
// lists the questions of an ask with several, each graded on its own; nil
// means one decision.
type JudgeInput struct {
	Situation, Owner, Twin string
	Questions              []string
}

// Judge grades the twin's decision against the owner's real one in the
// situation: one grade per question (one when Questions is empty), in
// order. The backtest asks it for every item but an exact match on a fixed
// option.
type Judge interface {
	Grade(ctx context.Context, in JudgeInput) ([]string, *digest.Usage, error)
}

// NewLLMJudge judges on the strong tier (prompts.WatchmanJudge).
func NewLLMJudge(gen digest.Generator, store *prompts.Store) Judge {
	return llmJudge{gen: gen, store: store}
}

type llmJudge struct {
	gen   digest.Generator
	store *prompts.Store
}

// Grade asks the model once. A reply that is not {"grades": [...]} with at
// least one grade, every one known, is an error (with the call's Usage): the backtest cannot
// score the item, and guessing would bend the number. A list of the wrong
// length is returned as it is; the backtest counts a missing grade bad.
func (j llmJudge) Grade(ctx context.Context, in JudgeInput) ([]string, *digest.Usage, error) {
	questions := in.Questions
	if questions == nil {
		questions = []string{}
	}
	// json.Marshal escapes '<' and '>', so no text can close the fence.
	body, err := json.Marshal(struct {
		Situation string   `json:"situation"`
		Owner     string   `json:"owner"`
		Twin      string   `json:"twin"`
		Questions []string `json:"questions"`
	}{in.Situation, in.Owner, in.Twin, questions})
	if err != nil {
		return nil, nil, fmt.Errorf("watchman judge: encoding the answers: %w", err)
	}
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template (the Decide precedent).
	tmpl, _, _ := prompts.Resolve(j.store, prompts.WatchmanJudge, "")
	raw, usage, _, err := j.gen.Generate(digest.WithSource(ctx, prompts.WatchmanJudge), tmpl,
		"=== DATA ===\n<data>\n"+string(body)+"\n</data>\n", "")
	if err != nil {
		return nil, usage, fmt.Errorf("watchman judge: generating: %w", err)
	}
	var r struct {
		Grades []struct {
			Grade string `json:"grade"`
		} `json:"grades"`
	}
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &r); err != nil {
		return nil, usage, fmt.Errorf("watchman judge: the reply is not a JSON object: %w", err)
	}
	if len(r.Grades) == 0 {
		return nil, usage, fmt.Errorf("watchman judge: the reply has no \"grades\"")
	}
	out := make([]string, 0, len(r.Grades))
	for _, g := range r.Grades {
		switch g.Grade {
		case GradeSame, GradeAcceptable, GradeBad:
			out = append(out, g.Grade)
		default:
			return nil, usage, fmt.Errorf("watchman judge: unknown grade %q", g.Grade)
		}
	}
	return out, usage, nil
}
