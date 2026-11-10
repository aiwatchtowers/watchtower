package providers

import "testing"

// LLMUSAGE-01 / N3: runtime B's old "http" rows read as ollama; every other
// label as is.
func TestLLMUSAGE01_LedgerLabelHTTPReadsAsOllama(t *testing.T) {
	for in, want := range map[string]string{"http": "ollama", "claude": "claude", "codex": "codex", "ollama": "ollama", "": ""} {
		if got := LedgerLabel(in); got != want {
			t.Errorf("LedgerLabel(%q) = %q, want %q", in, got, want)
		}
	}
}
