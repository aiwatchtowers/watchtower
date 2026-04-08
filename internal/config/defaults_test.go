package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestDefaultJiraFeatures_IC(t *testing.T) {
	f := DefaultJiraFeatures("ic")
	assert.True(t, f.MyIssuesInBriefing)
	assert.True(t, f.AwaitingMyInput)
	assert.True(t, f.WhoPing)
	assert.True(t, f.TrackJiraLinking)
	assert.False(t, f.TeamWorkload)
	assert.False(t, f.BlockerMap)
	assert.False(t, f.IterationProgress)
	assert.False(t, f.EpicProgress)
	assert.False(t, f.WriteBackSuggestions)
	assert.False(t, f.ReleaseDashboard)
	assert.False(t, f.WithoutJiraDetection)
}

func TestDefaultJiraFeatures_SeniorIC(t *testing.T) {
	f := DefaultJiraFeatures("senior_ic")
	assert.True(t, f.MyIssuesInBriefing)
	assert.True(t, f.AwaitingMyInput)
	assert.True(t, f.WhoPing)
	assert.True(t, f.TrackJiraLinking)
	assert.True(t, f.BlockerMap)
	assert.True(t, f.WriteBackSuggestions)
	assert.True(t, f.WithoutJiraDetection)
	assert.False(t, f.TeamWorkload)
	assert.False(t, f.IterationProgress)
	assert.False(t, f.EpicProgress)
	assert.False(t, f.ReleaseDashboard)
}

func TestDefaultJiraFeatures_MiddleManagement(t *testing.T) {
	f := DefaultJiraFeatures("middle_management")
	assert.True(t, f.MyIssuesInBriefing)
	assert.True(t, f.TeamWorkload)
	assert.True(t, f.IterationProgress)
	assert.False(t, f.EpicProgress)
	assert.False(t, f.ReleaseDashboard)
}

func TestDefaultJiraFeatures_DirectionOwner(t *testing.T) {
	f := DefaultJiraFeatures("direction_owner")
	assert.True(t, f.WhoPing)
	assert.True(t, f.EpicProgress)
	assert.True(t, f.WithoutJiraDetection)
	assert.False(t, f.MyIssuesInBriefing)
	assert.False(t, f.TeamWorkload)
}

func TestDefaultJiraFeatures_TopManagement(t *testing.T) {
	f := DefaultJiraFeatures("top_management")
	assert.True(t, f.TrackJiraLinking)
	assert.True(t, f.TeamWorkload)
	assert.True(t, f.ReleaseDashboard)
	assert.True(t, f.EpicProgress)
	assert.False(t, f.MyIssuesInBriefing)
	assert.False(t, f.WhoPing)
}

func TestDefaultJiraFeatures_UnknownRole(t *testing.T) {
	// Unknown role should default to IC.
	f := DefaultJiraFeatures("unknown_role")
	ic := DefaultJiraFeatures("ic")
	assert.Equal(t, ic, f)
}

func TestRoleDisplayNames(t *testing.T) {
	assert.Equal(t, "IC", RoleDisplayNames["ic"])
	assert.Equal(t, "Tech Lead", RoleDisplayNames["senior_ic"])
	assert.Equal(t, "EM", RoleDisplayNames["middle_management"])
	assert.Equal(t, "Director", RoleDisplayNames["top_management"])
	assert.Equal(t, "PM", RoleDisplayNames["direction_owner"])
}
