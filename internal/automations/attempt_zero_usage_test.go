package automations_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerrouting"
)

// Both authoritative zero shapes must survive the physical leaf -> attempt
// hook -> SDK meter -> persisted replay boundary, without inventing uncertainty.
func TestRoutingAuthoritativeZeroUsageSurvivesHookAndReplay(t *testing.T) {
	for _, kind := range []string{"reported_zero", "never_started"} {
		t.Run(kind, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				sink := &collectingSink{}
				llmusage.SetSink(sink)
				t.Cleanup(func() { llmusage.SetSink(nil) })
				path := filepath.Join(t.TempDir(), "fake-claude")
				if kind == "reported_zero" {
					script := "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"done\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}'\n"
					require.NoError(t, os.WriteFile(path, []byte(script), 0o700))
				}
				leaf := digest.NewClaudeGenerator("haiku", "opus", path)
				cfg := &config.Config{}
				cfg.AI.Provider = "claude"
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
				reserve := &routedTestLeaf{provider: "codex"}
				gen := providerrouting.WrapGenerator(cfg, leaf, func(p string) digest.Generator {
					if p == "claude" {
						return leaf
					}
					return reserve
				}, providerrouting.GeneratorOptions{Router: &providerrouting.Router{}})
				w := newWriteFixtureOpts(t, exOpts{gen: gen})
				script := `try{llm("first")}catch(e){};` + resumeAskCall + `;try{return llm("after resume")}catch(e){return e.name}`
				a := w.seedWorkbenchOutput(t, "known-zero", []string{"ask:owner", "llm:light"}, "inbox", script)
				id := w.enqueue(t, a, db.TriggerManual)
				w.stopWhileWaiting(t, id)
				before := w.run(t, id)
				require.Zero(t, before.InputTokens+before.OutputTokens)
				require.False(t, before.TokensEstimated)
				records, err := w.d.ListAutomationRunReplay(id)
				require.NoError(t, err)
				require.Len(t, records, 2)
				require.True(t, strings.HasPrefix(records[0].ClockJSON, "["))
				require.NotContains(t, records[0].ClockJSON, "unknown_model_usage")
				var dbPath string
				require.NoError(t, w.d.QueryRow(`SELECT file FROM pragma_database_list WHERE name='main'`).Scan(&dbPath))
				require.NoError(t, w.d.Close())
				reopened, err := db.Open(dbPath)
				require.NoError(t, err)
				*w.d = *reopened
				w.restart()
				stop := runExecutor(t, w.exFixture)
				defer stop()
				w.waitStatus(t, id, db.RunWaiting)
				w.answerAsk(t, w.onlyAsk(t, a.ProjectID).ID)
				w.e.Wake()
				run := w.waitEnded(t, id)
				require.Equal(t, db.RunSucceeded, run.Status, run.Error)
				want := "done"
				if kind == "never_started" {
					want = automations.ErrNameTool
				}
				require.Equal(t, want, run.Summary, "further admission must not be barred by false uncertainty")
				require.Zero(t, run.InputTokens+run.OutputTokens)
				require.False(t, run.TokensEstimated)
				require.Zero(t, reserve.calls)
				calls := sink.snapshot()
				require.Len(t, calls, 2, "both separate model admissions reached the leaf")
				for _, c := range calls {
					require.Zero(t, c.Input+c.Output+c.CacheRead+c.CacheWrite5m+c.CacheWrite1h)
					require.False(t, c.Estimated)
					require.Equal(t, kind == "reported_zero", c.OK)
				}
				steps := w.steps(t, id)
				require.Len(t, steps, 3)
				for _, s := range steps {
					require.Zero(t, s.InputTokens+s.OutputTokens)
					require.False(t, s.TokensEstimated)
				}
			})
		})
	}
}
