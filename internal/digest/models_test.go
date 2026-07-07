package digest

import "testing"

func TestModelForSource(t *testing.T) {
	haiku := []string{SourceLight, "inbox.triage", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel"}
	for _, src := range haiku {
		if got := ModelForSource(src); got != ModelHaiku {
			t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelHaiku)
		}
	}

	sonnet := []string{
		"digest.channel", "digest.daily", "digest.weekly",
		"tracks.extract_batch", "people.reduce", "people.team",
		"briefing.daily", "inbox.card", "", "unknown.source",
	}
	for _, src := range sonnet {
		if got := ModelForSource(src); got != ModelSonnet {
			t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelSonnet)
		}
	}
}
