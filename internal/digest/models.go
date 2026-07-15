package digest

const (
	ModelHaiku  = "claude-haiku-4-5-20251001"
	ModelSonnet = "claude-sonnet-4-6"
)

// ModelForSource returns the optimal model for a given pipeline source.
// Lightweight classification/rollup tasks use Haiku; quality-critical analysis uses Sonnet.
func ModelForSource(source string) string {
	switch source {
	case SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "customtrack.compose", "customtrack.shortlist", "memory.extract_episodes":
		return ModelHaiku
	default:
		return ModelSonnet
	}
}
