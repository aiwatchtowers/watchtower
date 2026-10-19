package jira

import (
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// TrackerScope names the trackers a tracker-neutral read may cover (spec
// 2026-10-15-linear-integration-design §3.5): "jira" when only jira.enabled is
// on, "linear" when only linear.enabled is on, "" (both) when both are on, and
// ok=false when neither is. A reader passes the scope as its tracker filter, so
// a tracker that is switched off contributes nothing even when its rows are
// still stored — Jira behaviour stays identical with Linear off and vice versa.
func TrackerScope(cfg *config.Config) (tracker string, ok bool) {
	if cfg == nil {
		return "", false
	}
	switch {
	case cfg.Jira.Enabled && cfg.Linear.Enabled:
		return "", true
	case cfg.Jira.Enabled:
		return db.TrackerJira, true
	case cfg.Linear.Enabled:
		return db.TrackerLinear, true
	}
	return "", false
}

// TrackerFeatureScope is TrackerScope for a surface behind one of the Jira
// feature toggles, which govern both trackers (their config keys keep their
// names): ok=false when no tracker is enabled or the toggle is off.
func TrackerFeatureScope(cfg *config.Config, feature string) (tracker string, ok bool) {
	tracker, ok = TrackerScope(cfg)
	if !ok {
		return "", false
	}
	val, known := FeatureValue(&cfg.Jira.Features, feature)
	if !known || !val {
		return "", false
	}
	return tracker, true
}

// ScopeCovers reports whether a scope from TrackerScope includes tracker.
func ScopeCovers(scope, tracker string) bool { return scope == "" || scope == tracker }
