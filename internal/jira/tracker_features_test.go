package jira

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/config"
)

func TestTrackerScopeAndFeatureScope(t *testing.T) {
	cases := []struct {
		jira, linear, toggle bool
		scope                string
		ok, featureOK        bool
	}{
		{false, false, true, "", false, false},
		{true, false, true, "jira", true, true},
		{false, true, true, "linear", true, true},
		{true, true, true, "", true, true},
		{true, true, false, "", true, false},
	}
	for _, c := range cases {
		cfg := &config.Config{}
		cfg.Jira.Enabled, cfg.Linear.Enabled = c.jira, c.linear
		cfg.Jira.Features.MyIssuesInBriefing = c.toggle
		scope, ok := TrackerScope(cfg)
		assert.Equal(t, c.scope, scope, "%+v", c)
		assert.Equal(t, c.ok, ok, "%+v", c)
		fscope, fok := TrackerFeatureScope(cfg, "my_issues")
		assert.Equal(t, c.featureOK, fok, "%+v", c)
		if fok {
			assert.Equal(t, c.scope, fscope)
		}
		_, unknown := TrackerFeatureScope(cfg, "no_such_toggle")
		assert.False(t, unknown)
	}
	_, ok := TrackerScope(nil)
	assert.False(t, ok)
	assert.True(t, ScopeCovers("", "jira"))
	assert.True(t, ScopeCovers("linear", "linear"))
	assert.False(t, ScopeCovers("jira", "linear"))
}
