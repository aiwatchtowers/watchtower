package cmd

import (
	"context"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providers"
)

// refusedProvider stands in for a provider the organization's policy
// (AllowedAIProviders, #608) forbids: every call fails with the policy error
// and no provider process ever starts. There is no fallback to an allowed
// provider.
type refusedProvider struct{ err error }

var (
	_ digest.Generator = refusedProvider{}
	_ ai.Provider      = refusedProvider{}
)

func (r refusedProvider) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	return "", nil, "", r.err
}

func (r refusedProvider) Query(context.Context, string, string, string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	chunks, errs, ids := make(chan ai.StreamChunk), make(chan error, 1), make(chan string)
	errs <- r.err
	close(chunks)
	close(errs)
	close(ids)
	return chunks, errs, ids
}

func (r refusedProvider) QuerySync(context.Context, string, string, string) (string, *ai.Usage, error) {
	return "", nil, r.err
}

// policyCheckedGenerator asks the policy before every call: a long-lived
// generator (the daemon's pipelines) follows a profile installed or changed
// while it runs, through the policy's 30 s cache.
type policyCheckedGenerator struct {
	inner    digest.Generator
	provider string
}

func (g policyCheckedGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *digest.Usage, string, error) {
	if err := providers.Allowed(g.provider); err != nil {
		return "", nil, "", err
	}
	return g.inner.Generate(ctx, systemPrompt, userMessage, sessionID)
}

// checkedGenerator is the configured provider's generator behind a per-call
// policy check, for the unattended paths that keep one generator for long.
func checkedGenerator(cfg *config.Config) digest.Generator {
	return policyCheckedGenerator{inner: buildGenerator(cfg), provider: cfg.AI.Provider}
}

// policyCheckedBackend asks the policy at every turn of a warm `ai session`:
// a forbidden provider answers the turn with the policy error instead of
// reaching the provider.
type policyCheckedBackend struct {
	chat.Backend
	provider string
}

func (b policyCheckedBackend) Turn(ctx context.Context, c chat.Command, emit func(chat.Event)) error {
	if err := providers.Allowed(b.provider); err != nil {
		emit(chat.Event{Type: chat.EventError, TurnID: c.TurnID, Code: chat.CodeProviderUnavailable, Message: err.Error()})
		return err
	}
	return b.Backend.Turn(ctx, c, emit)
}
