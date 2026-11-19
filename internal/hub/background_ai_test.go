package hub

import (
	"testing"

	"watchtower/internal/aiconsent"
	"watchtower/internal/hub/wire"
)

func TestBackgroundAIValue(t *testing.T) {
	cases := []struct {
		name string
		in   aiconsent.State
		want string
	}{
		{"allowed by the owner", aiconsent.State{Effective: aiconsent.EffectiveAllowed, Reason: aiconsent.ReasonOwner}, wire.BackgroundAIAllowed},
		{"paused by the organization", aiconsent.State{Effective: aiconsent.EffectivePaused, Reason: aiconsent.ReasonOrganization, Locked: true}, wire.BackgroundAIOrganization},
		{"paused by the owner", aiconsent.State{Effective: aiconsent.EffectivePaused, Reason: aiconsent.ReasonOwner}, wire.BackgroundAIPaused},
		{"unanswered", aiconsent.State{Effective: aiconsent.EffectivePaused, Reason: aiconsent.ReasonUnanswered, Prompt: true}, wire.BackgroundAIPaused},
	}
	for _, c := range cases {
		if got := backgroundAIValue(c.in); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}
