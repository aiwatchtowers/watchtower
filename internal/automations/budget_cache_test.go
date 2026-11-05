package automations_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
	"watchtower/internal/providerrouting"
)

// llm() debits the same quantity for the same work on claude and codex, with
// provider routing off or on: fresh (uncached) input plus output. The leaves
// are the real generators over fake CLIs: claude reports input_tokens without
// its cache reads and writes, codex's input_tokens includes
// cached_input_tokens. The leaf ledger keeps the full split either way.
func TestLLMBudgetDebitsUncachedInputOnEveryProvider(t *testing.T) {
	const (
		claudeOut = `{"type":"result","subtype":"success","result":"done","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":200,"output_tokens":50}}`
		codexOut  = `{"type":"item.completed","item":{"type":"agent_message","text":"done"}}` + "\n" +
			`{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50}}`
	)
	for _, tc := range []struct {
		name     string
		provider string
		routed   bool
	}{
		{"claude/direct", "claude", false},
		{"codex/direct", "codex", false},
		{"claude/routed", "claude", true},
		{"codex/routed", "codex", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			sink := &collectingSink{}
			llmusage.SetSink(sink)
			t.Cleanup(func() { llmusage.SetSink(nil) })
			leaves := map[string]digest.Generator{
				"claude": digest.NewClaudeGenerator("haiku", "opus", fakeCLI(t, claudeOut)),
				"codex":  codex.NewCodexGenerator("gpt-light", "gpt-strong", fakeCLI(t, codexOut)),
			}
			gen := leaves[tc.provider]
			if tc.routed {
				cfg := &config.Config{}
				cfg.AI.Provider = tc.provider
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: map[string]string{"claude": "codex", "codex": "claude"}[tc.provider]}
				gen = providerrouting.WrapGenerator(cfg, gen, func(p string) digest.Generator { return leaves[p] },
					providerrouting.GeneratorOptions{Router: &providerrouting.Router{Allowed: func(string) error { return nil }}})
			}
			f := newExFixture(t, exOpts{gen: gen})
			a := f.seedText(t, "cache-budget", exRecipeText(`return llm("task")`, ""), false)
			id := f.enqueue(t, a, db.TriggerManual)
			f.step(t, 1)
			run := f.wantRun(t, id, db.RunSucceeded, "")
			require.Equal(t, int64(100), run.InputTokens, "fresh input only")
			require.Equal(t, int64(50), run.OutputTokens)
			require.False(t, run.TokensEstimated)

			calls := sink.snapshot()
			require.Len(t, calls, 1)
			require.Equal(t, tc.provider, calls[0].Provider)
			require.Equal(t, int64(100), calls[0].Input, "the ledger's fresh input")
			require.Equal(t, int64(900), calls[0].CacheRead, "the ledger keeps the cache reads")
		})
	}
}

// fakeCLI is a CLI that drains stdin and prints out, whatever its arguments.
func fakeCLI(t *testing.T, out string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-cli")
	script := "#!/bin/sh\ncat >/dev/null\ncat <<'__OUT__'\n" + out + "\n__OUT__\n"
	require.NoError(t, os.WriteFile(path, []byte(script), 0o700))
	return path
}
