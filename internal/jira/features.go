package jira

import (
	"strings"

	"watchtower/internal/config"
)

// featureLabel maps toggle field names to human-readable labels.
var featureLabel = map[string]string{
	"my_issues":          "My Issues in Briefing",
	"awaiting_input":     "Awaiting My Input",
	"who_ping":           "Who to Ping",
	"track_linking":      "Track Jira Linking",
	"team_workload":      "Team Workload",
	"blocker_map":        "Blocker Map",
	"iteration_progress": "Iteration Progress",
	"epic_progress":      "Epic Progress",
	"write_back":         "Write-Back Suggestions",
	"release_dashboard":  "Release Dashboard",
	"without_jira":       "Without Jira Detection",
}

// featureOrder defines the display order.
var featureOrder = []string{
	"my_issues", "awaiting_input", "who_ping", "track_linking",
	"team_workload", "blocker_map", "iteration_progress", "epic_progress",
	"write_back", "release_dashboard", "without_jira",
}

// FeatureValue returns the bool value for a named feature.
func FeatureValue(f *config.JiraFeatureToggles, name string) (bool, bool) {
	switch name {
	case "my_issues":
		return f.MyIssuesInBriefing, true
	case "awaiting_input":
		return f.AwaitingMyInput, true
	case "who_ping":
		return f.WhoPing, true
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
	case "write_back":
		return f.WriteBackSuggestions, true
	case "release_dashboard":
		return f.ReleaseDashboard, true
	case "without_jira":
		return f.WithoutJiraDetection, true
	default:
		return false, false
	}
}

// BuildFeatureContext returns a string describing enabled/disabled features for LLM prompts.
func BuildFeatureContext(toggles config.JiraFeatureToggles) string {
	var enabled []string
	var disabled []string

	for _, name := range featureOrder {
		label := featureLabel[name]
		val, _ := FeatureValue(&toggles, name)
		if val {
			enabled = append(enabled, label)
		} else {
			disabled = append(disabled, label)
		}
	}

	var b strings.Builder
	b.WriteString("ENABLED JIRA FEATURES: ")
	if len(enabled) > 0 {
		b.WriteString(strings.Join(enabled, ", "))
	} else {
		b.WriteString("(none)")
	}
	b.WriteString("\nDISABLED: ")
	if len(disabled) > 0 {
		b.WriteString(strings.Join(disabled, ", "))
	} else {
		b.WriteString("(none)")
	}
	b.WriteString("\nGenerate content ONLY for enabled features.")
	return b.String()
}
