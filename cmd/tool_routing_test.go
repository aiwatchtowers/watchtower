package cmd

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

type toolRouteTestLeaf struct {
	calls     int
	sessionID string
	err       error
}

func (l *toolRouteTestLeaf) QuerySync(context.Context, string, string, string) (string, *ai.Usage, error) {
	l.calls++
	return "partial", nil, l.err
}
func (l *toolRouteTestLeaf) Query(ctx context.Context, s, u, id string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	c, e, ids := make(chan ai.StreamChunk, 1), make(chan error, 1), make(chan string, 1)
	text, _, err := l.QuerySync(ctx, s, u, id)
	c <- ai.StreamChunk{Text: text}
	if err != nil {
		e <- err
	}
	if l.sessionID != "" {
		ids <- l.sessionID
	}
	close(c)
	close(e)
	close(ids)
	return c, e, ids
}
func TestToolRoutingKnownQuotaAndStartedQuotaAreSingleCalls(t *testing.T) {
	policytest.Set(t, nil)
	for _, primary := range []string{"claude", "codex"} {
		t.Run(primary, func(t *testing.T) {
			reserve := "codex"
			if primary == reserve {
				reserve = "claude"
			}
			cfg := &config.Config{AI: config.AIConfig{Provider: primary, Fallback: config.AIFallbackConfig{Enabled: true, Provider: reserve}, Providers: map[string]config.AIProviderConfig{primary: {Models: config.AIModels{Strong: "preferred-model"}}, reserve: {Models: config.AIModels{Strong: "reserve-model"}}}}}
			health := providerhealth.New(t.TempDir(), nil)
			primaryLeaf := &toolRouteTestLeaf{err: &providers.Failure{Provider: primary, Category: providers.Quota, Cause: errors.New("quota")}}
			reserveLeaf := &toolRouteTestLeaf{}
			var selected []string
			p := newToolRouteProvider(cfg, func(actual *config.Config) (ai.Provider, func(), error) {
				selected = append(selected, actual.AI.Provider)
				if actual.AI.Provider == primary {
					return primaryLeaf, func() {}, nil
				}
				_, model := providers.ResolveModelsFor(actual, reserve)
				require.Equal(t, "reserve-model", model)
				return reserveLeaf, func() {}, nil
			})
			p.router = &providerrouting.Router{Health: health}
			text, _, err := p.QuerySync(context.Background(), "system", "owner", "")
			require.Error(t, err)
			require.Equal(t, "partial", text)
			require.Equal(t, 1, primaryLeaf.calls)
			require.Zero(t, reserveLeaf.calls)
			_, _, err = p.QuerySync(context.Background(), "system", "new owner", "")
			require.NoError(t, err)
			require.Equal(t, []string{primary, reserve}, selected)
			_, _, err = p.QuerySync(context.Background(), "system", "native turn", "native-id")
			require.Error(t, err)
			require.Equal(t, 1, primaryLeaf.calls)
			require.Equal(t, 1, reserveLeaf.calls)
		})
	}
}
func TestToolRoutingExplicitDefaultFlagsArePins(t *testing.T) {
	policytest.Set(t, nil)
	oldProvider := flagProvider
	t.Cleanup(func() { flagProvider = oldProvider })
	flagProvider = ""
	cfg := &config.Config{AI: config.AIConfig{Provider: "claude", Fallback: config.AIFallbackConfig{Enabled: true, Provider: "codex"}}}
	_, model := providers.ResolveModelsFor(cfg, "claude")
	_, routed := newAIClientWithModel(cfg, "", model).(*toolRouteProvider)
	require.False(t, routed)
	flagProvider = "claude"
	_, routed = newAIClient(cfg, "").(*toolRouteProvider)
	require.False(t, routed)
	flagProvider = ""
	_, routed = newAIClient(cfg, "").(*toolRouteProvider)
	require.True(t, routed)
}

func TestToolRoutingReturnedNativeIDStaysWithActualProviderAndModel(t *testing.T) {
	policytest.Set(t, nil)
	for _, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			reserve := "codex"
			if preferred == reserve {
				reserve = "claude"
			}
			cfg := &config.Config{AI: config.AIConfig{Provider: preferred, Fallback: config.AIFallbackConfig{Enabled: true, Provider: reserve}, Providers: map[string]config.AIProviderConfig{reserve: {Models: config.AIModels{Strong: "reserve-model"}}}}}
			health := providerhealth.New(t.TempDir(), nil)
			require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope(preferred, ""), &providers.Failure{Provider: preferred, Category: providers.Quota}))
			leaf := &toolRouteTestLeaf{sessionID: "synthetic-native-thread"}
			builds := 0
			p := newToolRouteProvider(cfg, func(actual *config.Config) (ai.Provider, func(), error) {
				builds++
				require.Equal(t, reserve, actual.AI.Provider)
				_, model := providers.ResolveModelsFor(actual, reserve)
				require.Equal(t, "reserve-model", model)
				return leaf, func() {}, nil
			})
			p.router = &providerrouting.Router{Health: health}
			stream := func(sid string) string {
				chunks, errs, ids := p.Query(context.Background(), "system", "question", sid)
				for c := range chunks {
					if c.Routing != nil {
						require.Equal(t, reserve, c.Routing.Provider)
						require.Equal(t, "reserve-model", c.Routing.Model)
					}
				}
				next := ""
				for id := range ids {
					next = id
				}
				for err := range errs {
					require.NoError(t, err)
				}
				return next
			}
			sid := stream("")
			require.Equal(t, "synthetic-native-thread", sid)
			cfg.AI.Providers[reserve] = config.AIProviderConfig{Models: config.AIModels{Strong: "changed-preference"}}
			require.Equal(t, sid, stream(sid))
			require.Equal(t, 2, builds)
			require.Equal(t, 2, leaf.calls)
			_, _, err := p.QuerySync(context.Background(), "system", "question", "unknown-native-thread")
			var failure *providers.Failure
			require.ErrorAs(t, err, &failure)
			require.Equal(t, providers.Capability, failure.Category)
			require.NotContains(t, err.Error(), "unknown-native-thread")
			require.Equal(t, 2, builds)
		})
	}
}
