package digest

// Tier identifies the model class a pipeline source routes to. Concrete
// model names per tier live in the provider registry (internal/providers)
// and in each generator's configuration — never here.
type Tier string

const (
	TierLight  Tier = "light"
	TierStrong Tier = "strong"
)

// TierForSource classifies a pipeline source tag into a model tier.
// Lightweight classification/rollup tasks route to the light tier;
// quality-critical analysis routes to the strong tier. This is the single
// source→tier table for every Generator backend (Claude, Codex, Ollama).
func TierForSource(source string) Tier {
	switch source {
	case SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "customtrack.compose", "customtrack.shortlist", "memory.extract_episodes", "memory.extract_episodes_batch", "memory.extract_email_episodes", "memory.render_channel_digest", "meeting.followup", "meeting.speaker_guess", "ideas.digest_email", "ideas.digest_jira", "dictation.clean":
		return TierLight
	default:
		return TierStrong
	}
}
