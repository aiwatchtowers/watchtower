package jira

import (
	"watchtower/internal/config"
)

// FeatureValue returns the bool value for a named feature.
func FeatureValue(f *config.JiraFeatureToggles, name string) (bool, bool) {
	switch name {
	case "my_issues":
		return f.MyIssuesInBriefing, true
	case "awaiting_input":
		return f.AwaitingMyInput, true
	case "track_linking":
		return f.TrackJiraLinking, true
	case "team_workload":
		return f.TeamWorkload, true
	case "blocker_map":
		return f.BlockerMap, true
	case "iteration_progress":
		return f.IterationProgress, true
	case "epic_progress":
		return f.EpicProgress, true
	case "release_dashboard":
		return f.ReleaseDashboard, true
	case "without_jira":
		return f.WithoutJiraDetection, true
	default:
		return false, false
	}
}
