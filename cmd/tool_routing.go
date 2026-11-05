package cmd

import (
	"context"
	"errors"
	"log"
	"maps"
	"sync"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

// toolRouteProvider binds each logical Query to exactly one selected provider.
// Factories preserve the existing tool/connection/read-folder configuration.
type toolRouteProvider struct {
	cfg             *config.Config
	router          *providerrouting.Router
	build           func(*config.Config) (ai.Provider, func(), error)
	readFolder      string
	chatEvents      bool
	capable         func(string) (bool, error)
	mu              sync.Mutex
	nativeProviders map[string]toolNativeSession
}

type toolNativeSession struct{ provider, model string }

func toolRoutingEnabled(cfg *config.Config, model string) bool {
	return cfg.AI.Fallback.Enabled && flagProvider == "" && model == "" && (cfg.AI.ConfiguredProvider == "" || cfg.AI.ConfiguredProvider == cfg.AI.Provider)
}
func newToolRouteProvider(cfg *config.Config, build func(*config.Config) (ai.Provider, func(), error)) *toolRouteProvider {
	health, err := providerhealth.Installation()
	if err != nil {
		log.Printf("AI tool routing: %v", err)
	}
	return &toolRouteProvider{cfg: cfg, build: build, router: &providerrouting.Router{Health: health, Diagnostic: func(err error) { log.Printf("AI tool routing: %v", err) }}}
}
func (p *toolRouteProvider) SetReadFolder(dir string) { p.readFolder = dir }

// EmitToolEvents switches the chat events on for every leaf it builds
// (enableChatEvents).
func (p *toolRouteProvider) EmitToolEvents() { p.chatEvents = true }

// configureLeaf hands the selected provider's leaf what was set on the
// router: the read folder (refused as a capability error when the leaf has
// no file tools) and the chat events.
func (p *toolRouteProvider) configureLeaf(selected string, leaf ai.Provider) error {
	if p.readFolder != "" {
		c, ok := leaf.(readFolderConfigurable)
		if !ok {
			return providers.CapabilityError(selected, providers.ReviewReadonly,
				errors.New("--read-folder: the selected provider has no file tools, so it cannot read the folder"))
		}
		c.SetReadFolder(p.readFolder)
	}
	if p.chatEvents {
		enableChatEvents(leaf)
	}
	return nil
}
func (p *toolRouteProvider) request(sessionID string) providerrouting.Request {
	preferred := p.cfg.AI.Provider
	p.mu.Lock()
	binding := p.nativeProviders[sessionID]
	if binding.provider != "" {
		preferred = binding.provider
	}
	p.mu.Unlock()
	mode := providerrouting.PreferredReserve
	// A native thread cannot cross providers. Existing callers carrying one
	// remain bound; main chat uses Watchtower replay instead.
	if sessionID != "" {
		mode = providerrouting.Pinned
	}
	return providerrouting.Request{Preferred: preferred, Reserve: p.cfg.AI.Fallback.Provider, Mode: mode, Tier: digest.TierStrong, Profile: providers.ToolPreflight, Retry: providerrouting.BeforeChild, Revision: providers.RoutingRevision(p.cfg),
		Model: func(id string, _ digest.Tier) string {
			if binding.provider == id && binding.model != "" {
				return binding.model
			}
			_, m := providers.ResolveModelsFor(p.cfg, id)
			return m
		},
		CheckCapability: func(id string, _ providers.InvocationProfile) (bool, error) {
			if p.capable != nil {
				supported, err := p.capable(id)
				if err != nil || !supported {
					return supported, err
				}
			}
			return id == "claude" || id == "codex", nil
		}}
}
func (p *toolRouteProvider) run(ctx context.Context, sid string, call func(context.Context, ai.Provider, providerrouting.Attempt) (providerrouting.Result, error)) (providerrouting.Result, error) {
	if err := p.cfg.AI.Validate(); err != nil {
		return providerrouting.Result{}, err
	}
	if sid != "" {
		p.mu.Lock()
		binding := p.nativeProviders[sid]
		p.mu.Unlock()
		if binding.provider == "" {
			return providerrouting.Result{}, providers.CapabilityError(p.cfg.AI.Provider, providers.ToolPreflight, errors.New("native session provider is unknown; pass --provider or start a fresh session"))
		}
	}
	req := p.request(sid)
	selected, err := p.router.Select(ctx, req)
	if err != nil {
		return providerrouting.Result{}, err
	}
	actual := *p.cfg
	actual.AI = p.cfg.AI
	actual.AI.Provider = selected
	actual.AI.Fallback.Enabled = false
	if sid != "" {
		actual.AI.Providers = maps.Clone(p.cfg.AI.Providers)
		if actual.AI.Providers == nil {
			actual.AI.Providers = map[string]config.AIProviderConfig{}
		}
		bucket := actual.AI.Providers[selected]
		bucket.Models.Strong = req.Model(selected, req.Tier)
		actual.AI.Providers[selected] = bucket
	}
	leaf, cleanup, err := p.build(&actual)
	if err != nil {
		return providerrouting.Result{}, err
	}
	defer cleanup()
	if err := p.configureLeaf(selected, leaf); err != nil {
		return providerrouting.Result{}, err
	}
	req.Preferred, req.Mode, req.Retry = selected, providerrouting.Pinned, providerrouting.Never
	return p.router.Run(ctx, req, func(callCtx context.Context, attempt providerrouting.Attempt) (providerrouting.Result, error) {
		return call(callCtx, leaf, attempt)
	})
}
func (p *toolRouteProvider) Query(ctx context.Context, system, user, sid string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	chunks, errs, ids := make(chan ai.StreamChunk), make(chan error, 1), make(chan string, 1)
	go func() {
		defer close(chunks)
		defer close(errs)
		defer close(ids)
		_, err := p.run(ctx, sid, func(callCtx context.Context, leaf ai.Provider, attempt providerrouting.Attempt) (providerrouting.Result, error) {
			reason := ""
			if attempt.Provider != p.cfg.AI.Provider {
				reason = "quota_exhausted"
			}
			if sid != "" {
				reason = "explicit_pin"
			}
			select {
			case chunks <- ai.StreamChunk{Routing: &ai.RoutingMetadata{Provider: attempt.Provider, Model: attempt.Model, PreferredProvider: p.cfg.AI.Provider, Mode: string(p.request(sid).Mode), Reason: reason}}:
			case <-callCtx.Done():
				return providerrouting.Result{}, callCtx.Err()
			}
			textCh, errCh, idCh := leaf.Query(callCtx, system, user, sid)
			for c := range textCh {
				select {
				case chunks <- c:
				case <-callCtx.Done():
				}
			}

			for id := range idCh {
				if id != "" {
					p.mu.Lock()
					if p.nativeProviders == nil {
						p.nativeProviders = map[string]toolNativeSession{}
					}
					p.nativeProviders[id] = toolNativeSession{attempt.Provider, attempt.Model}
					p.mu.Unlock()
				}
				select {
				case ids <- id:
				default:
				}
			}
			var failure error
			for e := range errCh {
				if failure == nil {
					failure = e
				}
			}
			return providerrouting.Result{}, failure
		})
		if err != nil {
			errs <- err
		}
	}()
	return chunks, errs, ids
}
func (p *toolRouteProvider) QuerySync(ctx context.Context, system, user, sid string) (string, *ai.Usage, error) {
	var usage *ai.Usage
	result, err := p.run(ctx, sid, func(callCtx context.Context, leaf ai.Provider, attempt providerrouting.Attempt) (providerrouting.Result, error) {
		text, u, err := leaf.QuerySync(callCtx, system, user, sid)
		usage = u
		return providerrouting.Result{Text: text}, err
	})
	return result.Text, usage, err
}
