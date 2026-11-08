package cmd

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"

	"github.com/stretchr/testify/require"
)

// A real strict leaf consumes each owned response file afresh. This lets a new
// factory after a simulated restart share only persisted health, never a child.
func integrationRoutingLeaf(t *testing.T, provider, response string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	output := filepath.Join(dir, "response")
	require.NoError(t, os.WriteFile(output, []byte(response), 0600))
	bin := filepath.Join(dir, provider)
	script := "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.166.0'; exit; fi\ncat >/dev/null\ncat '" + output + "'\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0700))
	return bin, output
}

type integrationRecoveryGate struct {
	entered chan struct{}
	release chan struct{}
}

func (h *integrationRecoveryGate) Before(ctx context.Context, _ providerrouting.Attempt) error {
	close(h.entered)
	select {
	case <-h.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (*integrationRecoveryGate) After(context.Context, providerrouting.Attempt, providerrouting.Outcome) error {
	return nil
}

func TestRoutingIntegrationStrictLeavesDeferredRestartAndRealRecovery(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			policytest.Set(t, nil)
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CODEX_HOME", t.TempDir())
			reserve := "codex"
			if preferred == reserve {
				reserve = "claude"
			}
			// Primary selected-model Codex display format: protocol/src/error.rs
			// rust-v0.166.0:691-708. The exact selected bucket must survive composition.
			quotas := map[string]string{
				"claude": `{"type":"result","subtype":"error_during_execution","is_error":true,"error":{"type":"usage_limit_reached"},"result":"quota"}`,
				"codex":  `{"type":"turn.failed","error":{"message":"You’ve hit your usage limit for GPT-5.6-Sol. Switch to another model now, or try again later."}}`,
			}
			successes := map[string]string{
				"claude": `{"type":"result","subtype":"success","result":"[]","usage":{"input_tokens":11,"cache_read_input_tokens":7,"cache_creation_input_tokens":5,"output_tokens":3},"total_cost_usd":0.25}`,
				"codex":  "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"[]\"}}\n" + `{"type":"turn.completed","usage":{"input_tokens":18,"cached_input_tokens":7,"output_tokens":3}}`,
			}
			cfg := &config.Config{Digest: config.DigestConfig{Enabled: true, MinMessages: 3}}
			cfg.AI.Provider, cfg.AI.ConfiguredProvider = preferred, preferred
			cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: reserve}
			cfg.AI.Providers = map[string]config.AIProviderConfig{"codex": {Models: config.AIModels{Light: "gpt-5.6-sol", Strong: "gpt-5.6-sol"}}}
			outputs := map[string]string{}
			cfg.ClaudePath, outputs["claude"] = integrationRoutingLeaf(t, "claude", quotas["claude"])
			cfg.CodexPath, outputs["codex"] = integrationRoutingLeaf(t, "codex", quotas["codex"])
			var clock atomic.Int64
			clock.Store(time.Now().Add(-2 * time.Hour).UnixNano())
			now := func() time.Time { return time.Unix(0, clock.Load()) }
			dir := t.TempDir()
			makeGenerator := func() digest.Generator {
				router := &providerrouting.Router{Health: providerhealth.New(dir, now), Now: now}
				return providerrouting.WrapGenerator(cfg, legacyCLIGenerator(cfg), func(provider string) digest.Generator {
					local := *cfg
					local.AI.Provider = provider
					return checkedGenerator(&local)
				}, providerrouting.GeneratorOptions{Router: router, Timeout: 5 * time.Second})
			}
			sink := &ledgerSink{}
			llmusage.SetSink(sink)
			t.Cleanup(func() { llmusage.SetSink(nil) })
			ctx, cancel := context.WithTimeout(digest.WithSource(context.Background(), "digest.channel_batch"), 10*time.Second)
			defer cancel()
			database := db.OpenTestDB(t)
			from := float64(time.Now().Add(-20 * 24 * time.Hour).Unix())
			to := from + 86400
			require.NoError(t, database.UpsertUser(db.User{ID: "fixture-user", Name: "fixture"}))
			for _, channel := range []string{"1:C1", "1:C2"} {
				require.NoError(t, database.UpsertChannel(db.Channel{ID: channel, Name: channel, Type: "public"}))
				for i := range 4 {
					require.NoError(t, database.UpsertMessage(db.Message{ChannelID: channel, UserID: "fixture-user",
						TS: fmt.Sprintf("%.6f", from+3600+float64(i*60)), Text: fmt.Sprintf("owned pending input %d", i)}))
				}
			}
			runPending := func(callCtx context.Context, generator digest.Generator) (digest.BackfillWindowResult, error) {
				result, _, callErr := digest.New(database, cfg, generator, log.New(io.Discard, "", 0)).RunBackfillWindow(callCtx, 1, from, to)
				return result, callErr
			}
			gen := makeGenerator()
			pending, err := runPending(ctx, gen)
			require.False(t, pending.Complete)
			var deferred *providerrouting.Deferred
			require.ErrorAs(t, err, &deferred)
			require.True(t, digest.ProviderDeferred(err))
			require.ErrorIs(t, err, digest.ErrAICall)
			require.Equal(t, 2, deferred.Attempts)
			require.Len(t, sink.calls, 2)
			require.Equal(t, preferred, sink.calls[0].Provider)
			require.Equal(t, reserve, sink.calls[1].Provider)
			require.Equal(t, sink.calls[0].OperationID, sink.calls[1].OperationID)
			require.NotEmpty(t, sink.calls[0].OperationID)
			for i, call := range sink.calls {
				require.Equal(t, i+1, call.Attempt)
			}
			health := providerhealth.New(dir, now)
			codexAccount, err := health.Peek(ctx, providerhealth.AccountScope("codex", ""))
			require.NoError(t, err)
			require.Equal(t, providerhealth.Available, codexAccount.State, "named model quota must not block the entire account")
			codexModel, err := health.Peek(ctx, providerhealth.ModelScope(providerhealth.AccountScope("codex", ""), "gpt-5.6-sol"))
			require.NoError(t, err)
			require.Equal(t, providerhealth.QuotaWait, codexModel.State)
			// Recreate the complete routing object: the persisted cooldown prevents
			// both paid attempts; the eligible source still owns its pending input.
			gen = makeGenerator()
			_, err = runPending(ctx, gen)
			require.ErrorAs(t, err, &deferred)
			require.Zero(t, deferred.Attempts)
			require.Len(t, sink.calls, 2)
			// Reserve is still exhausted when preferred becomes due. Two independent
			// callers share the persisted preferred lease, even after recreation.
			reserveScope := providerhealth.AccountScope(reserve, "")
			if reserve == "codex" {
				reserveScope = providerhealth.ModelScope(reserveScope, "gpt-5.6-sol")
			}
			require.NoError(t, health.RecordQuota(ctx, reserveScope, &providers.Failure{
				Provider: reserve, Category: providers.Quota, ResetAt: time.Now().Add(time.Hour),
			}))
			// Only actual pending work after reset clears the block, not reading status.
			clock.Store(time.Now().UnixNano())
			require.NoError(t, os.WriteFile(outputs[preferred], []byte(successes[preferred]), 0600))
			gate := &integrationRecoveryGate{entered: make(chan struct{}), release: make(chan struct{})}
			done := make(chan error, 1)
			joined := make(chan struct{})
			go func() {
				defer close(joined)
				result, callErr := runPending(providerrouting.WithAttemptHook(ctx, gate), gen)
				if callErr == nil && !result.Complete {
					callErr = fmt.Errorf("pending history input was not completed")
				}
				done <- callErr
			}()
			t.Cleanup(func() { cancel(); <-joined })
			select {
			case <-gate.entered:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			_, _, _, err = makeGenerator().Generate(ctx, "", "another pending safe batch", "")
			require.ErrorAs(t, err, &deferred)
			require.Zero(t, deferred.Attempts, "the competing caller cannot claim the held recovery lease")
			close(gate.release)
			require.NoError(t, <-done)

			require.Len(t, sink.calls, 3)
			recovered := sink.calls[2]
			require.Equal(t, preferred, recovered.Provider)
			require.Equal(t, 1, recovered.Attempt)
			require.NotEqual(t, sink.calls[0].OperationID, recovered.OperationID)
			require.Equal(t, int64(11), recovered.Input)
			require.Equal(t, int64(7), recovered.CacheRead)
			require.Equal(t, int64(3), recovered.Output)
			require.False(t, recovered.Estimated)
			if preferred == "claude" {
				require.Equal(t, int64(5), recovered.CacheWrite5m)
				require.NotNil(t, recovered.ReportedCostUSD)
				require.Equal(t, 0.25, *recovered.ReportedCostUSD)
			} else {
				require.Nil(t, recovered.ReportedCostUSD, "estimated pricing is not reported cost")
			}
			// Durable declined completion survives another pipeline instance; there
			// is no inference replay for the same pending input claim.
			completed, err := database.HistoryBackfillConsidered(1, from, to)
			require.NoError(t, err)
			require.Len(t, completed, 2)
			pending, err = runPending(ctx, makeGenerator())
			require.NoError(t, err)
			require.True(t, pending.Complete)
			require.Len(t, sink.calls, 3)
			// Subsequent background computation remains preferred; reserve's cooldown
			// is still independent and has not been cleared by preferred success.
			_, _, _, err = makeGenerator().Generate(ctx, "", "next safe batch", "")
			require.NoError(t, err)
			require.Len(t, sink.calls, 4)
			require.Equal(t, preferred, sink.calls[3].Provider)
		})
	}
}
