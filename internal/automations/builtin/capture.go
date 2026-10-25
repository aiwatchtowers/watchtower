package builtin

import (
	"context"
	"fmt"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// CapturePrompts returns the prompt each primitive call of a's current text
// would make, by primitive name ("ideas.consolidate" → its prompt; the first
// call of a primitive wins): a dry run in memory that calls no primitive and
// stops at any model call made before one (ideas mine --from runs today's
// drain with the recipe's prompt and writes no run row). a must be confirmed
// (else ErrNotRunnable): only confirmed text lends its prompt.
func CapturePrompts(ctx context.Context, b automations.Backends, a *db.Automation) (map[string]string, error) {
	if a == nil || !a.Confirmed() {
		return nil, fmt.Errorf("capturing prompts: the recipe is not confirmed: %w", automations.ErrNotRunnable)
	}
	r, err := automations.ParseRecipe(a.Slug, []byte(a.RecipeText), automations.ScopeOf(*a))
	if err != nil {
		return nil, fmt.Errorf("capturing the prompts of %s: %w", a.Slug, err)
	}
	if automations.ApprovalHash(r) != a.ConfirmedHash {
		return nil, fmt.Errorf("capturing the prompts of %s: the text is not the confirmed one: %w", a.Slug, automations.ErrNotRunnable)
	}
	prompts := map[string]string{}
	rep, err := automations.DryRunInMemory(ctx, b, r, automations.DryRunOptions{
		StopAtModelCalls: true,
		CapturePrompts: func(primitive, prompt string) {
			if _, ok := prompts[primitive]; !ok {
				prompts[primitive] = prompt
			}
		},
	})
	if err != nil {
		return nil, fmt.Errorf("capturing the prompts of %s: %w", a.Slug, err)
	}
	if rep.Status != db.RunSucceeded {
		return nil, fmt.Errorf("capturing the prompts of %s: the dry run ended %s: %s", a.Slug, rep.Status, rep.Error)
	}
	return prompts, nil
}
