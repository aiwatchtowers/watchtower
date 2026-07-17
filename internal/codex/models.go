package codex

import "watchtower/internal/digest"

const (
	ModelDefault     = "gpt-5.4"
	ModelLightweight = "gpt-5.4-mini"
)

// ModelForSource returns the optimal Codex model for a given pipeline source.
// Lightweight classification/rollup tasks use the mini model; quality-critical analysis uses the default.
// Honors digest.SourceLight as the cross-harness contract for lightweight routing.
func ModelForSource(source string) string {
	switch source {
	case digest.SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "customtrack.compose", "customtrack.shortlist", "memory.extract_episodes", "memory.extract_episodes_batch":
		return ModelLightweight
	default:
		return ModelDefault
	}
}
