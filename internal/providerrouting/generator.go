package providerrouting

import (
	"context"
	"log"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

// GeneratorOptions is supplied by the host factory. Legacy is returned exactly
// when routing is off/pinned. Leaves must share the host's existing worker pool;
// they must not install separate per-attempt deadlines.
type GeneratorOptions struct {
	Timeout  time.Duration
	Pinned   bool
	Router   *Router
	Identity func(provider string) string
}

// WrapGenerator enables only isolated text/image calls. SDK automation remains
// on Legacy until Task7 installs an explicit attempt meter via WithAttemptHook.
// Factory is lazy construction only; it does not check auth or invoke a CLI.
func WrapGenerator(cfg *config.Config, legacy digest.Generator, factory func(string) digest.Generator, opts GeneratorOptions) digest.Generator {
	if !cfg.AI.Fallback.Enabled || opts.Pinned {
		return legacy
	}
	if err := cfg.AI.Validate(); err != nil {
		return digest.RefusedGenerator{Err: err}
	}
	r := opts.Router
	if r == nil {
		health, err := providerhealth.Installation()
		r = &Router{Health: health, Diagnostic: func(err error) { log.Printf("AI routing: %v", err) }}
		r.diagnostic(err)
	}
	models := map[string][2]string{}
	for _, id := range []string{cfg.AI.Provider, cfg.AI.Fallback.Provider} {
		l, s := providers.ResolveModelsFor(cfg, id)
		models[id] = [2]string{l, s}
	}
	return &generator{legacy: legacy, factory: factory, router: r, preferred: cfg.AI.Provider, reserve: cfg.AI.Fallback.Provider, revision: providers.RoutingRevision(cfg), models: models, identity: opts.Identity, timeout: opts.Timeout}
}

type generator struct {
	timeout                      time.Duration
	dropEnv                      []string
	legacy                       digest.Generator
	factory                      func(string) digest.Generator
	router                       *Router
	preferred, reserve, revision string
	models                       map[string][2]string
	identity                     func(string) string
}
type hookKey struct{}

// WithAttemptHook opts an automation call into routing only after its meter can
// admit/debit every attempt. Other factory users need no hook.
func WithAttemptHook(ctx context.Context, h AttemptHook) context.Context {
	return context.WithValue(ctx, hookKey{}, h)
}
func (g *generator) excluded(ctx context.Context) bool {
	if h, _ := ctx.Value(hookKey{}).(AttemptHook); h != nil {
		return false
	}
	_, _, automation := llmusage.AutomationFrom(ctx)
	source, _ := digest.SourceFromContext(ctx)
	return automation || strings.HasPrefix(source, "automation.")
}
func (g *generator) request(ctx context.Context, profile providers.InvocationProfile, leaves map[string]digest.Generator) Request {
	tier := digest.TierForContext(ctx)
	// Routed image leaves use strong for both providers without changing purpose.
	if profile == providers.Image {
		tier = digest.TierStrong
	}
	hook, _ := ctx.Value(hookKey{}).(AttemptHook)
	return Request{Preferred: g.preferred, Reserve: g.reserve, Mode: PreferredReserve, Tier: tier, Profile: profile, Retry: Isolated, Revision: g.revision, Identity: g.identity, Hook: hook,
		Model: func(p string, t digest.Tier) string {
			if t == digest.TierLight {
				return g.models[p][0]
			}
			return g.models[p][1]
		},
		Capable: func(p string, profile providers.InvocationProfile) bool {
			if profile != providers.Image {
				return profile == providers.BatchText
			}
			_, ok := digest.ImageCapable(leaves[p])
			return ok
		}}
}
func (g *generator) leaves() map[string]digest.Generator {
	leaves := map[string]digest.Generator{g.preferred: g.factory(g.preferred), g.reserve: g.factory(g.reserve)}
	for _, leaf := range leaves {
		if s, ok := leaf.(interface{ SetIsolatedChild(...string) }); ok {
			s.SetIsolatedChild(g.dropEnv...)
		}
	}
	return leaves
}
func (g *generator) Generate(ctx context.Context, system, user, session string) (string, *digest.Usage, string, error) {
	if g.excluded(ctx) {
		return g.legacy.Generate(ctx, system, user, session)
	}
	if g.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, g.timeout)
		defer cancel()
	}
	leaves := g.leaves()
	result, err := g.router.Run(ctx, g.request(ctx, providers.BatchText, leaves), func(ctx context.Context, a Attempt) (Result, error) {
		// Isolated attempts never exchange provider-native session identifiers.
		text, usage, id, err := leaves[a.Provider].Generate(ctx, system, user, "")
		return Result{Text: text, Usage: usage, SessionID: id}, err
	})
	return result.Text, result.Usage, result.SessionID, err
}

// ImageCapability is consumed by digest.ImageCapable without bypassing policy.
func (g *generator) ImageCapability() bool {
	_, ok := digest.ImageCapable(g.factory(g.preferred))
	return ok
}
func (g *generator) GenerateWithImage(ctx context.Context, system, user, path, media string) (string, *digest.Usage, error) {
	if g.excluded(ctx) {
		inner, ok := digest.ImageCapable(g.legacy)
		if !ok {
			return "", nil, providers.CapabilityError(g.preferred, providers.Image, nil)
		}
		return inner.GenerateWithImage(ctx, system, user, path, media)
	}
	if g.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, g.timeout)
		defer cancel()
	}
	ctx = digest.WithModelTier(ctx, digest.TierStrong)
	leaves := g.leaves()
	result, err := g.router.Run(ctx, g.request(ctx, providers.Image, leaves), func(ctx context.Context, a Attempt) (Result, error) {
		inner, ok := digest.ImageCapable(leaves[a.Provider])
		if !ok {
			return Result{}, providers.CapabilityError(a.Provider, providers.Image, nil)
		}
		text, usage, err := inner.GenerateWithImage(ctx, system, user, path, media)
		return Result{Text: text, Usage: usage}, err
	})
	return result.Text, result.Usage, err
}

// SetIsolatedChild retains host environment scrubbing on both physical leaves.
func (g *generator) SetIsolatedChild(dropEnv ...string) {
	g.dropEnv = append([]string(nil), dropEnv...)
	if s, ok := g.legacy.(interface{ SetIsolatedChild(...string) }); ok {
		s.SetIsolatedChild(dropEnv...)
	}
}
func (g *generator) CallTimeout() (time.Duration, bool) { return g.timeout, g.timeout > 0 }

// Preflight is a metadata-only scheduler seam. Legacy generators have no new
// health gate; routed generators recheck atomically when the real call starts.
func Preflight(ctx context.Context, gen digest.Generator) error {
	if check, ok := gen.(interface{ RoutingPreflight(context.Context) error }); ok {
		return check.RoutingPreflight(ctx)
	}
	return nil
}
func (g *generator) RoutingPreflight(ctx context.Context) error {
	if g.excluded(ctx) {
		return nil
	}
	leaves := g.leaves()
	return g.router.Check(ctx, g.request(ctx, providers.BatchText, leaves))
}
