package guide

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// maxAccomplishments is the cap on resolved issues listed in the delivery section.
const maxAccomplishments = 10

// jiraDeliveryInstruction is appended to the people card prompt when Jira
// delivery data is present. It tells the AI how to use the section: tracker
// facts become work topics and accomplishments, never a judgment of the
// person (#1769, spec §5.1 rule 7 — no Jira+Slack compound signals).
const jiraDeliveryInstruction = `
If JIRA DELIVERY data is provided above, use it as facts about the work:
- List resolved issues as concrete accomplishments.
- Use expertise tags to identify the work topics they know.
- Never turn issue counts, overdue issues or cycle times into a judgment of the person, and never combine them with Slack activity.`

// gatherJiraDelivery collects issue-tracker delivery context (Jira and Linear,
// from tracker_issues, enabled trackers only) for a single user; the section
// keeps its JIRA header.
// Returns an empty string (no error) when no tracker is connected, the
// my_issues toggle is off, or the user has no tracker activity. The caller can
// safely append the result to the AI prompt.
func gatherJiraDelivery(database *db.DB, cfg *config.Config, userSlackID, from, to string) (string, error) {
	scope, ok := jira.TrackerFeatureScope(cfg, "my_issues")
	if !ok {
		return "", nil
	}

	stats, err := database.GetTrackerDeliveryStats(scope, userSlackID, from, to)
	if err != nil {
		return "", fmt.Errorf("jira delivery stats for %s: %w", userSlackID, err)
	}
	if stats == nil {
		return "", nil
	}

	// Skip entirely when there is no Jira activity at all.
	if stats.IssuesClosed == 0 && stats.OpenIssues == 0 && stats.OverdueIssues == 0 &&
		stats.StoryPointsCompleted == 0 && len(stats.Components) == 0 && len(stats.Labels) == 0 {
		return "", nil
	}

	var b strings.Builder
	b.WriteString("=== JIRA DELIVERY ===\n")

	// Metrics line.
	fmt.Fprintf(&b, "Issues closed: %d, Avg cycle time: %.1f days, Story points: %.1f\n",
		stats.IssuesClosed, stats.AvgCycleTimeDays, stats.StoryPointsCompleted)
	fmt.Fprintf(&b, "Open issues: %d, Overdue: %d\n", stats.OpenIssues, stats.OverdueIssues)

	// Expertise tags from components + labels.
	expertise := jira.MergeUnique(stats.Components, stats.Labels)
	if len(expertise) > 0 {
		fmt.Fprintf(&b, "Expertise: [%s]\n", strings.Join(expertise, ", "))
	}

	// Recent accomplishments: resolved issues within the period (bounded query).
	accomplishments, err := database.GetTrackerResolvedIssuesForUser(scope, userSlackID, from, to, maxAccomplishments)
	if err == nil && len(accomplishments) > 0 {
		b.WriteString("\nRecent accomplishments:\n")
		for _, issue := range accomplishments {
			// resolved_at is stored in UTC; the owner's day is the local one.
			resolvedDate := issue.ResolvedAt
			if unix, ok := db.ParseJiraTime(resolvedDate); ok {
				resolvedDate = time.Unix(unix, 0).Format("2006-01-02")
			} else if len(resolvedDate) > 10 {
				resolvedDate = resolvedDate[:10]
			}
			fmt.Fprintf(&b, "- Resolved %s %q (%s)\n", issue.Key, issue.Title, resolvedDate)
		}
	}

	return b.String(), nil
}
