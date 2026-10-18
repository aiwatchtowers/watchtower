package jira

import "watchtower/internal/config"

// TrackerFeatureEnabled is IsFeatureEnabled for a tracker-neutral surface
// (spec 2026-10-15-linear-integration-design §3.5): the existing Jira feature
// toggles govern the behaviour for both trackers, so the surface is on when
// either tracker is connected (jira.enabled or linear.enabled) and the toggle
// is on. Their config keys keep their names.
func TrackerFeatureEnabled(cfg *config.Config, feature string) bool {
	if cfg == nil || (!cfg.Jira.Enabled && !cfg.Linear.Enabled) {
		return false
	}
	val, known := FeatureValue(&cfg.Jira.Features, feature)
	return known && val
}
