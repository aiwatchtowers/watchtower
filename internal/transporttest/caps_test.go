package transporttest

import (
	"testing"

	"watchtower/internal/providers"
)

// llmRow is the production-shaped part of a suite Caps row: the fields of
// the spec's §3.3 table that providers.Capabilities also holds.
// ClaudeAITools and ReservePeer are not transport behaviour the suite
// drives, so they are left zero on both sides.
func llmRow(c Caps) providers.Capabilities {
	return providers.Capabilities{Tools: c.Tools, ToolEvents: c.ToolEvents, TextStream: c.TextStream,
		Usage: c.Usage, CostReported: c.CostReported, Images: c.Images, PDFs: c.PDFs, WebSearch: c.WebSearch,
		ReadFolder: c.ReadFolder, TurnCap: c.TurnCap, Interrupt: c.Interrupt, WarmSession: c.WarmSession,
		Quota: c.Quota}
}

// TestTransportSuite_LLMCapsMatchProviders: the suite's LLM capability rows
// are the ones the consumers decide by (internal/providers/caps), so a
// production capability that changes flips the suite's cells and the golden
// in the same reviewed diff (spec §4.3). The raw ollama row is suite-only:
// it is the production "ollama" row (runtime B's) without the tool loop.
func TestTransportSuite_LLMCapsMatchProviders(t *testing.T) {
	seen := map[string]bool{}
	for _, a := range adapters {
		prod, ok := providers.CapsFor(a.Provider)
		if !ok {
			t.Errorf("%s: provider %q has no production capability row", a.Name, a.Provider)
			continue
		}
		prod.ClaudeAITools, prod.ReservePeer = false, ""
		if a.Name == "ollama" {
			prod.Tools, prod.ToolEvents, prod.TurnCap = "none", false, "none"
		}
		if got := llmRow(a.Caps); got != prod {
			t.Errorf("%s: suite caps\n  %+v\ndisagree with providers.CapsFor(%q)\n  %+v", a.Name, got, a.Provider, prod)
		}
		seen[a.Provider] = true
	}
	for _, id := range []string{"claude", "codex", "ollama"} {
		if !seen[id] {
			t.Errorf("provider %q has no adapter in the suite", id)
		}
	}
}
