package watchman

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// Judge rates whether the twin's free-text decision is the same decision as
// the owner's real one in situation (spec 2026-11-16-watchman-design §9).
// The backtest asks it only for items with no fixed options.
type Judge interface {
	Same(ctx context.Context, situation, owner, twin string) (bool, *digest.Usage, error)
}

// NewLLMJudge judges on the light tier (prompts.WatchmanJudge).
func NewLLMJudge(gen digest.Generator, store *prompts.Store) Judge {
	return llmJudge{gen: gen, store: store}
}

type llmJudge struct {
	gen   digest.Generator
	store *prompts.Store
}

// Same asks the model once. A reply that is not {"same": true|false} is an
// error (with the call's Usage): the backtest cannot score the item, and
// guessing either way would bend the number.
func (j llmJudge) Same(ctx context.Context, situation, owner, twin string) (bool, *digest.Usage, error) {
	// json.Marshal escapes '<' and '>', so no text can close the fence.
	body, err := json.Marshal(struct {
		Situation string `json:"situation"`
		Owner     string `json:"owner"`
		Twin      string `json:"twin"`
	}{situation, owner, twin})
	if err != nil {
		return false, nil, fmt.Errorf("watchman judge: encoding the answers: %w", err)
	}
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template (the Decide precedent).
	tmpl, _, _ := prompts.Resolve(j.store, prompts.WatchmanJudge, "")
	raw, usage, _, err := j.gen.Generate(digest.WithSource(ctx, prompts.WatchmanJudge), tmpl,
		"=== DATA ===\n<data>\n"+string(body)+"\n</data>\n", "")
	if err != nil {
		return false, usage, fmt.Errorf("watchman judge: generating: %w", err)
	}
	var r struct {
		Same *bool `json:"same"`
	}
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &r); err != nil {
		return false, usage, fmt.Errorf("watchman judge: the reply is not a JSON object: %w", err)
	}
	if r.Same == nil {
		return false, usage, fmt.Errorf("watchman judge: the reply has no \"same\"")
	}
	return *r.Same, usage, nil
}
