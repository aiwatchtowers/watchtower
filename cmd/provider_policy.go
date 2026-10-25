package cmd

import (
	"context"
	"fmt"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/policy"
	"watchtower/internal/providers"
)

// refusedProvider stands in for a provider the organization's policy
// (AllowedAIProviders, #608) forbids, as a digest.Generator and an
// ai.Provider: every call fails with the policy error and no provider process
// ever starts. There is no fallback to an allowed provider.
type refusedProvider struct{ digest.RefusedGenerator }

var (
	_ digest.Generator = refusedProvider{}
	_ ai.Provider      = refusedProvider{}
)

func newRefusedProvider(err error) refusedProvider {
	return refusedProvider{digest.RefusedGenerator{Err: err}}
}

// Query delivers the error before the stream ends: errs is buffered and
// holds it when the channels close, so a caller that drains text, then the
// session id, then errs (streamQueryV1) reports it.
func (r refusedProvider) Query(context.Context, string, string, string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	chunks, errs, ids := make(chan ai.StreamChunk), make(chan error, 1), make(chan string)
	errs <- r.Err
	close(errs)
	close(chunks)
	close(ids)
	return chunks, errs, ids
}

func (r refusedProvider) QuerySync(context.Context, string, string, string) (string, *ai.Usage, error) {
	return "", nil, r.Err
}

// policyCheckedProvider asks the policy before every call: a long-lived
// client (the daemon's Jira board analyzer, the tool registry's) follows a
// profile installed, changed or removed while it runs. Interactive paths keep
// newAIClient's construction-time check, which leaves the client's own
// type (its MCP setters) intact.
type policyCheckedProvider struct {
	inner    ai.Provider
	provider string
}

func (p policyCheckedProvider) Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	if err := providers.Allowed(p.provider); err != nil {
		return newRefusedProvider(err).Query(ctx, systemPrompt, userMessage, sessionID)
	}
	return p.inner.Query(ctx, systemPrompt, userMessage, sessionID)
}

func (p policyCheckedProvider) QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *ai.Usage, error) {
	if err := providers.Allowed(p.provider); err != nil {
		return "", nil, err
	}
	return p.inner.QuerySync(ctx, systemPrompt, userMessage, sessionID)
}

// checkedAIClient is the configured provider's client behind a per-call
// policy check, for the long-lived holders.
func checkedAIClient(cfg *config.Config, dbPath string) ai.Provider {
	return policyCheckedProvider{inner: buildAIClient(cfg, dbPath, ""), provider: cfg.AI.Provider}
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

// policyCheckedBackend asks the policy at every turn of a warm `ai session`
// (#608, spec §5): a forbidden provider answers the turn with the policy
// error; a Quick Connection the session mounted, or its claude.ai mode, that
// the policy now forbids ends the session (`end`), so the app's pool starts
// a new one under the current policy.
type policyCheckedBackend struct {
	chat.Backend
	provider   string
	mounted    []ai.ExternalMCPServer
	claudeAIOn bool
	end        func()
}

func (b policyCheckedBackend) Turn(ctx context.Context, c chat.Command, emit func(chat.Event)) error {
	if err := providers.Allowed(b.provider); err != nil {
		emit(chat.Event{Type: chat.EventError, TurnID: c.TurnID, Code: chat.CodeProviderUnavailable, Message: err.Error()})
		return err
	}
	if err := b.staleMounts(); err != nil {
		emit(chat.Event{Type: chat.EventError, TurnID: c.TurnID, Code: chat.CodeSessionLost, Retryable: true,
			Message: err.Error() + "; the chat restarts under the current policy"})
		if b.end != nil {
			b.end()
		}
		return err
	}
	return b.Backend.Turn(ctx, c, emit)
}

// staleMounts is the policy refusal of something this session mounted at its
// start: a Quick Connection or the claude.ai tools.
func (b policyCheckedBackend) staleMounts() error {
	for _, m := range b.mounted {
		if err := connectionPolicyError(m.Name, m.Kind, m.URL, m.Command); err != nil {
			return err
		}
	}
	if b.claudeAIOn && !policy.ClaudeAIToolsAllowed() {
		return fmt.Errorf("policy: claude.ai tools are %w", policy.ErrNotAllowed)
	}
	return nil
}
