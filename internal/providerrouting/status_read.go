package providerrouting

import (
	"context"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/providers"
)

// Output is what `watchtower ai routing-status` prints about the routing
// itself: the routing revision, the preferred provider, whether fallback is
// on and the availability of each quota provider of the pair. The command
// adds its own application fields; the chat's routing catalog carries this
// as it is.
type Output struct {
	Revision          string   `json:"revision"`
	PreferredProvider string   `json:"preferred_provider"`
	Enabled           bool     `json:"enabled"`
	Providers         []Status `json:"providers"`
}

// ReadStatus reads the routing status of cfg's preferred and fallback
// providers (only a provider with a subscription quota has one). checkAgain
// reserves a metadata-only limits check (CheckStatus); otherwise the stored
// health is read (Status), never claiming a probe.
func ReadStatus(ctx context.Context, cfg *config.Config, r *Router, checkAgain bool) (Output, error) {
	out := Output{Revision: providers.RoutingRevision(cfg), PreferredProvider: cfg.AI.ConfiguredProviderID(),
		Enabled: cfg.AI.Fallback.Enabled, Providers: []Status{}}
	req := Request{Tier: digest.TierStrong, Model: func(p string, _ digest.Tier) string {
		_, model := providers.ResolveModelsFor(cfg, p)
		return model
	}}
	for _, p := range []string{out.PreferredProvider, cfg.AI.Fallback.Provider} {
		if p == "" {
			continue
		}
		if c, ok := providers.CapsFor(p); !ok || !c.Quota {
			continue // only a provider with a subscription quota has a status
		}
		var status Status
		var err error
		if checkAgain {
			status, err = r.CheckStatus(ctx, req, p)
		} else {
			status, err = r.Status(ctx, req, p)
		}
		if err != nil {
			return out, err
		}
		out.Providers = append(out.Providers, status)
	}
	return out, nil
}
