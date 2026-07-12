package codex

import (
	"testing"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

func TestModelForSource(t *testing.T) {
	tests := []struct {
		source string
		want   string
	}{
		{digest.SourceLight, ModelLightweight},
		{"inbox.triage", ModelLightweight},
		{"digest.period", ModelLightweight},
		{"digest.channel_batch", ModelLightweight},
		{"people.batch", ModelLightweight},
		{"catchup.peel", ModelLightweight},
		{"digest.channel", ModelDefault},
		{"digest.daily", ModelDefault},
		{"tracks.create", ModelDefault},
		{"briefing.daily", ModelDefault},
		{"unknown", ModelDefault},
		{"", ModelDefault},
		{prompts.InboxCompose, ModelDefault},
		{prompts.InboxSituationCard, ModelDefault},
	}

	for _, tt := range tests {
		t.Run(tt.source, func(t *testing.T) {
			got := ModelForSource(tt.source)
			if got != tt.want {
				t.Errorf("ModelForSource(%q) = %q, want %q", tt.source, got, tt.want)
			}
		})
	}
}
