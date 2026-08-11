package digest

import (
	"testing"

	"watchtower/internal/prompts"
)

func TestModelForSource(t *testing.T) {
	haiku := []string{SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel", "memory.extract_episodes", "memory.extract_episodes_batch", "memory.extract_email_episodes", prompts.MemoryRenderChannelDigest, prompts.MeetingFollowup, prompts.DictationClean}
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
		// Phase-3 memory semantic tier routes strong (absence from the
		// light-tier switch above); Phase-4 reflection likewise.
		prompts.MemoryEntityRewrite, prompts.MemoryReviseBeliefs, prompts.MemoryRenderMap,
		prompts.MemoryReflect,
		// meeting.chapters routes strong by absence from the light-tier
		// switch (only the followup drafts are light).
		prompts.MeetingChapters,
	}
	for _, src := range sonnet {
		if got := ModelForSource(src); got != ModelSonnet {
			t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelSonnet)
		}
	}
}
