package providers

// LedgerLabel is the provider a reader shows for a label recorded in the
// LLM usage ledger (llm_calls, the spool). Runtime B recorded "http" until
// 2026-11-06 (its only base URL is ai.ollama_url), so "http" reads as
// "ollama" (N3, ask #514); no row is rewritten. Today only the usage llm
// spool reader takes a provider; a reader of llm_calls rows that takes one
// maps it here too. The mapping goes once the 90-day retention has aged the
// last such row out.
func LedgerLabel(recorded string) string {
	if recorded == "http" {
		return "ollama"
	}
	return recorded
}
