package digest

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/prompts"
)

func TestTierForSource(t *testing.T) {
	light := []string{SourceLight, "digest.period", "digest.channel_batch", "people.batch", "memory.extract_episodes", "memory.extract_episodes_batch", "memory.extract_email_episodes", prompts.MemoryRenderChannelDigest, prompts.MeetingFollowup, prompts.DictationClean, prompts.ReactionCommand, "catchup.learn", "automation.llm", "instructions.suggest"}
	for _, src := range light {
		if got := TierForSource(src); got != TierLight {
			t.Errorf("TierForSource(%q) = %q, want %q", src, got, TierLight)
		}
	}

	strong := []string{
		"digest.channel", "digest.daily", "digest.weekly",
		"tracks.extract_batch", "people.reduce", "people.team",
		"briefing.daily", "", "unknown.source",
		// Phase-3 memory semantic tier routes strong (absence from the
		// light-tier switch above); Phase-4 reflection likewise.
		prompts.MemoryEntityRewrite, prompts.MemoryReviseBeliefs, prompts.MemoryRenderMap,
		prompts.MemoryReflect,
		// meeting.chapters routes strong by absence from the light-tier
		// switch (only the followup drafts are light).
		prompts.MeetingChapters,
		// An automation's llm() with tier: strong.
		"automation.llm.strong",
		// The diff reviewer's overview: strong by absence from the light switch.
		"workbench.review_overview", "workbench.review_lessons",
		// The spec reviewer (spec 2026-10-25-spec-review-design §3).
		"workbench.spec_review",
		// The agent coach's weekly proposals (spec 2026-10-26-agent-coach-design §6).
		prompts.CoachPropose,
	}
	for _, src := range strong {
		if got := TierForSource(src); got != TierStrong {
			t.Errorf("TierForSource(%q) = %q, want %q", src, got, TierStrong)
		}
	}

	assert.Equal(t, TierStrong, TierForSource("catchup.compose"))
}

func TestTierForSource_Media(t *testing.T) {
	if got := TierForSource(prompts.MediaDescribe); got != TierStrong {
		t.Errorf("TierForSource(media.describe) = %q, want strong", got)
	}
	if got := TierForSource(prompts.MediaSummarizeLink); got != TierLight {
		t.Errorf("TierForSource(media.summarize_link) = %q, want light", got)
	}
}
