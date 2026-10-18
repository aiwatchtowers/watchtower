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
	case SourceLight, "digest.period", "digest.channel_batch", "people.batch", "customtrack.compose", "customtrack.shortlist", "memory.extract_episodes", "memory.extract_episodes_batch", "memory.extract_email_episodes", "memory.render_channel_digest", "meeting.followup", "ideas.digest_email", "ideas.digest_jira", "dictation.clean", "reactioncmd.command",
		// chat.title: a ≤60-char title from one exchange — bounded, fixed-shape output
		"chat.title",
		// terminal.title: a 3-6 word session name — same bounded shape
		"terminal.title",
		// workbench.ask_guard: the Stop ask guard's classifier — one turn's
		// final message to a fixed JSON verdict, inside a hook's budget
		"workbench.ask_guard",
		// The feedback-comment interpreter: a short comment + a fixed rating
		// turned into a bounded {rule_type, scope_key, weight, reason} list —
		// same shape/size class as ideas.digest_email/ideas.digest_jira above,
		// not the free-form synthesis the rest of the strong tier does
		// (decision 9, fix wave 4, task 6).
		"catchup.learn",
		// automation.llm: an owner automation's llm() call without
		// tier: strong (spec 2026-10-14-automations-design §5); the strong
		// twin automation.llm.strong stays strong by absence.
		"automation.llm",
		// instructions.suggest: the owner's repeated directions from 14 days of
		// workbench sessions to a bounded list of short lines Go validates
		"instructions.suggest":
		return TierLight
	default:
		return TierStrong
	}
}
