package tracks

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
	assert.Contains(t, got, "=== USER PROFILE CONTEXT ===\nRole: middle_management\nTeam: Platform\n\nOWNERSHIP RULES")
	assert.Contains(t, got, `MY REPORTS (user_ids): ["U20"]`)
	assert.Contains(t, got, `MY PEERS (user_ids): ["U30"]`)
	assert.Contains(t, got, "MY MANAGER (user_id): U40")
}

func TestFormatProfileContext_NoCustomContext_ReportsOnly(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Reports: `["U20"]`}}

	got := p.formatProfileContext()
	assert.Contains(t, got, "=== USER PROFILE CONTEXT ===\nOWNERSHIP RULES")
	assert.Contains(t, got, "MY REPORTS (user_ids)")
}

func TestFormatProfileContext_AllEmpty_NoBlock(t *testing.T) {
	for name, profile := range map[string]*db.UserProfile{
		"nil":         nil,
		"zero":        {},
		"empty lists": {Reports: "[]", Peers: "[]", StarredChannels: "[]", StarredPeople: "[]"},
	} {
		t.Run(name, func(t *testing.T) {
			p := &Pipeline{profile: profile}
			assert.Equal(t, "", p.formatProfileContext())
		})
	}
}

// A legacy profile with CustomPromptContext renders byte-for-byte as before:
// role and team are not repeated (the custom context was generated from them).
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

	want := "=== USER PROFILE CONTEXT ===\nI lead the platform team.\n\nOWNERSHIP RULES (based on user profile):\n- If the track is a task/question/request directed at ME → ownership: \"mine\"\n- If the track involves one of MY REPORTS as the responsible person → ownership: \"delegated\", owner_user_id: report's user_id\n- If the track is a decision/discussion that affects my area but I'm not the actor → ownership: \"watching\"\n- If unsure → ownership: \"mine\" (better to surface than miss)\n\nBALL RULES:\n- ball_on = user_id of the person who needs to act NEXT\n- If I asked a question and am waiting for reply → ball_on: other person's user_id\n- If someone asked me something → ball_on: my user_id\n\nMY REPORTS (user_ids): [\"U20\",\"U21\"]\nTasks assigned to or owned by these people → ownership: \"delegated\", owner_user_id: their user_id\n\nMY PEERS (user_ids): [\"U30\"]\n\nMY MANAGER (user_id): U40\n\nSTARRED CHANNELS: [\"C1\"] — create more tracks from these channels, lower threshold for relevance\n\nSTARRED PEOPLE: [\"U50\"] — messages from these people get higher priority\n"
	assert.Equal(t, want, p.formatProfileContext())
}

// Without a role, declared reports make the owner a manager.
func TestFormatRoleRules_EmptyRoleWithReports_IsManager(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Reports: `["U20"]`}}
	assert.Contains(t, p.formatRoleRules(), "DELEGATED TASKS")
}

func TestFormatRoleRules_EmptyRoleNoReports_NoRules(t *testing.T) {
	for name, reports := range map[string]string{"empty": "", "empty list": "[]"} {
		t.Run(name, func(t *testing.T) {
			p := &Pipeline{profile: &db.UserProfile{Reports: reports}}
			assert.Equal(t, "", p.formatRoleRules())
		})
	}
}

// An explicit non-manager role wins over declared reports.
func TestFormatRoleRules_ICRoleWithReports_NoRules(t *testing.T) {
	p := &Pipeline{profile: &db.UserProfile{Role: "ic", Reports: `["U20"]`}}
	assert.Equal(t, "", p.formatRoleRules())
}
