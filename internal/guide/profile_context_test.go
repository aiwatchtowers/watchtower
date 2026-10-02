package guide

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
)

// A profile filled by the team form carries no CustomPromptContext; its
// people and role must still reach the prompt.
func TestFormatProfileContext_NoCustomContext_RendersPeopleAndRole(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{
		Role:    "middle_management",
		Team:    "Platform",
		Reports: `["1:U20"]`,
		Peers:   `["1:U30"]`,
		Manager: "U40",
	}}

	got := p.formatProfileContext()
	assert.Contains(t, got, "=== VIEWER PROFILE CONTEXT ===\nRole: middle_management\nTeam: Platform\n\nCOACHING PERSONALIZATION")
	assert.Contains(t, got, `VIEWER'S REPORTS: ["U20"]`)
	assert.Contains(t, got, `VIEWER'S PEERS: ["U30"]`)
	assert.Contains(t, got, "VIEWER'S MANAGER: U40")
}

func TestFormatProfileContext_NoCustomContext_ReportsOnly(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Reports: `["U20"]`}}

	got := p.formatProfileContext()
	assert.Contains(t, got, "=== VIEWER PROFILE CONTEXT ===\nCOACHING PERSONALIZATION")
	assert.Contains(t, got, "VIEWER'S REPORTS")
}

func TestFormatProfileContext_AllEmpty_NoBlock(t *testing.T) {
	for name, profile := range map[string]*db.UserProfile{
		"nil":         nil,
		"zero":        {},
		"empty lists": {Reports: "[]", Peers: "[]"},
	} {
		t.Run(name, func(t *testing.T) {
			p := &Pipeline{profile: profile}
			assert.Equal(t, "", p.formatProfileContext())
		})
	}
}

// A legacy profile with CustomPromptContext renders byte-for-byte as before.
func TestFormatProfileContext_LegacyCustomContext_Unchanged(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{
		Role:                "middle_management",
		Team:                "Platform",
		CustomPromptContext: "I lead the platform team.",
		Reports:             `["1:U20","1:U21"]`,
		Peers:               `["1:U30"]`,
		Manager:             "U40",
		StarredChannels:     `["1:C1"]`,
		StarredPeople:       `["1:U50"]`,
	}}

	want := "=== VIEWER PROFILE CONTEXT ===\nI lead the platform team.\n\nCOACHING PERSONALIZATION:\n- Tailor communication advice to the viewer's role and responsibilities\n\nVIEWER'S REPORTS: [\"U20\",\"U21\"] — coaching for managing these people\n\nVIEWER'S PEERS: [\"U30\"] — coaching for peer collaboration\n\nVIEWER'S MANAGER: U40 — coaching for managing up\n"
	assert.Equal(t, want, p.formatProfileContext())
}
