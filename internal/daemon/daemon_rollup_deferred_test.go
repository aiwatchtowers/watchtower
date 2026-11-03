package daemon

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"

	"github.com/stretchr/testify/require"
)

func TestDaemon_RollupProviderDeferredPreservesPersistentMarkers(t *testing.T) {
	for _, known := range []bool{true, false} {
		t.Run(fmt.Sprintf("known=%v", known), func(t *testing.T) {
			d, database, _ := rollupBackoffTestSetup(t)
			cfg := d.config
			cfg.AI.Provider = "claude"
			cfg.AI.Fallback.Enabled = true
			cfg.AI.Fallback.Provider = "codex"
			store := providerhealth.New(t.TempDir(), nil)
			if known {
				for _, p := range []string{"claude", "codex"} {
					require.NoError(t, store.RecordQuota(context.Background(), providerhealth.AccountScope(p, ""), &providers.Failure{Provider: p, Category: providers.Quota}))
				}
			}
			calls := 0
			factory := func(p string) digest.Generator {
				return deferredPeopleLeaf{call: func() error { calls++; return &providers.Failure{Provider: p, Category: providers.Quota} }}
			}
			gen := providerrouting.WrapGenerator(cfg, factory("claude"), factory, providerrouting.GeneratorOptions{Router: &providerrouting.Router{Health: store, Allowed: func(string) error { return nil }}})
			d.SetDigestPipeline(digest.New(database, cfg, gen, d.logger))
			oldDate := rollupBudgetDate(time.Now().AddDate(0, 0, -1))
			require.NoError(t, saveAttemptMarker(d.rollupAttemptsPath(), attemptMarker{date: oldDate, attempts: 2}))
			d.loadRollupAttempts()
			before, err := os.ReadFile(d.rollupAttemptsPath())
			require.NoError(t, err)
			d.runRollupPhase(context.Background(), time.Now())
			after, err := os.ReadFile(d.rollupAttemptsPath())
			require.NoError(t, err)
			require.Equal(t, before, after)
			require.Equal(t, oldDate, d.rollupAttemptDate)
			require.Equal(t, 2, d.rollupAttempts)
			if known {
				require.Zero(t, calls)
			} else {
				require.Equal(t, 2, calls)
			}
			var count int
			require.NoError(t, database.QueryRow("SELECT count(*) FROM digests WHERE type='daily'").Scan(&count))
			require.Zero(t, count)
			restarted := newDaemon(nil, cfg)
			restarted.loadRollupAttempts()
			require.Equal(t, oldDate, restarted.rollupAttemptDate)
			require.Equal(t, 2, restarted.rollupAttempts)
		})
	}
}
