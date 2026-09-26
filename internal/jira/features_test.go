package jira

import (
	"testing"

	"watchtower/internal/config"

	"github.com/stretchr/testify/assert"
)

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
