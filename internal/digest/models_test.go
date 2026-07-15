package digest

import (
	"testing"

	"watchtower/internal/prompts"
)

func TestModelForSource(t *testing.T) {
	haiku := []string{SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "memory.extract_episodes"}
	for _, src := range haiku {
		if got := ModelForSource(src); got != ModelHaiku {
			t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelHaiku)
		}
	}

	sonnet := []string{
		"digest.channel", "digest.daily", "digest.weekly",
		"tracks.extract_batch", "people.reduce", "people.team",
		"briefing.daily", "", "unknown.source",
		prompts.InboxCompose, prompts.InboxSituationCard,
	}
	for _, src := range sonnet {
		if got := ModelForSource(src); got != ModelSonnet {
			t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelSonnet)
		}
	}
}
