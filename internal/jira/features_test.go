package jira

import (
	"strings"
	"testing"

	"watchtower/internal/config"

	"github.com/stretchr/testify/assert"
)

func TestBuildFeatureContext_AllEnabled(t *testing.T) {
	toggles := config.JiraFeatureToggles{
		MyIssuesInBriefing:   true,
		AwaitingMyInput:      true,
		WhoPing:              true,
		TrackJiraLinking:     true,
		TeamWorkload:         true,
		BlockerMap:           true,
		IterationProgress:    true,
		EpicProgress:         true,
		WriteBackSuggestions: true,
		ReleaseDashboard:     true,
		WithoutJiraDetection: true,
	}

	result := BuildFeatureContext(toggles)
	assert.Contains(t, result, "ENABLED JIRA FEATURES:")
	assert.Contains(t, result, "My Issues in Briefing")
	assert.Contains(t, result, "DISABLED: (none)")
	assert.Contains(t, result, "Generate content ONLY for enabled features.")
}

func TestBuildFeatureContext_NoneEnabled(t *testing.T) {
	toggles := config.JiraFeatureToggles{}
	result := BuildFeatureContext(toggles)
	assert.Contains(t, result, "ENABLED JIRA FEATURES: (none)")
	assert.Contains(t, result, "DISABLED: My Issues in Briefing")
}

func TestBuildFeatureContext_Partial(t *testing.T) {
	toggles := config.DefaultJiraFeatures("ic")
	result := BuildFeatureContext(toggles)
	assert.Contains(t, result, "My Issues in Briefing")
	assert.Contains(t, result, "Who to Ping")
	// Team workload should be disabled for IC.
	lines := strings.Split(result, "\n")
	assert.True(t, len(lines) >= 2)
	assert.Contains(t, lines[1], "Team Workload")
}

func TestFeatureValue(t *testing.T) {
	toggles := config.JiraFeatureToggles{MyIssuesInBriefing: true}

	val, ok := FeatureValue(&toggles, "my_issues")
	assert.True(t, ok)
	assert.True(t, val)

	val, ok = FeatureValue(&toggles, "team_workload")
	assert.True(t, ok)
	assert.False(t, val)

	_, ok = FeatureValue(&toggles, "nonexistent")
	assert.False(t, ok)
}
