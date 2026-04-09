package jira

import (
	"sort"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// WorkloadSignal classifies a team member's workload level.
type WorkloadSignal string

const (
	SignalNormal   WorkloadSignal = "normal"
	SignalWatch    WorkloadSignal = "watch"
	SignalOverload WorkloadSignal = "overload"
	SignalLow      WorkloadSignal = "low"
)

// WorkloadEntry holds compound workload metrics for a single team member,
// combining Jira issues, Slack message volume, and calendar meeting hours.
type WorkloadEntry struct {
	SlackUserID       string         `json:"slack_user_id"`
	DisplayName       string         `json:"display_name"`
	OpenIssues        int            `json:"open_issues"`
	StoryPoints       float64        `json:"story_points"`
	OverdueCount      int            `json:"overdue_count"`
	BlockedCount      int            `json:"blocked_count"`
	AvgCycleTimeDays  float64        `json:"avg_cycle_time_days"`
	SlackMessageCount int            `json:"slack_message_count"`
	MeetingHours      float64        `json:"meeting_hours"`
	Signal            WorkloadSignal `json:"signal"`
}

// signalPriority returns a sort key for signal ordering (overload first, then watch, low, normal).
func signalPriority(s WorkloadSignal) int {
	switch s {
	case SignalOverload:
		return 0
	case SignalWatch:
		return 1
	case SignalLow:
		return 2
	default:
		return 3
	}
}

// computeSignal determines the workload signal for a single entry.
func computeSignal(openIssues, overdueCount, blockedCount, slackMessages int) WorkloadSignal {
	if overdueCount > 2 || blockedCount > 3 || openIssues > 15 {
		return SignalOverload
	}
	if overdueCount > 0 || blockedCount > 1 || openIssues > 10 {
		return SignalWatch
	}
	if openIssues == 0 && slackMessages < 5 {
		return SignalLow
	}
	return SignalNormal
}

// ComputeTeamWorkload builds compound workload entries by combining Jira metrics,
// Slack message volume, and calendar meeting hours for the given time range.
// Returns nil, nil if the team_workload feature is disabled.
func ComputeTeamWorkload(d *db.DB, cfg *config.Config, from, to time.Time) ([]WorkloadEntry, error) {
	if !IsFeatureEnabled(cfg, "team_workload") {
		return nil, nil
	}

	jiraRows, err := d.GetJiraTeamWorkload()
	if err != nil {
		return nil, err
	}

	if len(jiraRows) == 0 {
		return nil, nil
	}

	entries := make([]WorkloadEntry, 0, len(jiraRows))
	for _, r := range jiraRows {
		e := WorkloadEntry{
			SlackUserID:      r.SlackUserID,
			DisplayName:      r.DisplayName,
			OpenIssues:       r.OpenIssues,
			StoryPoints:      r.StoryPoints,
			OverdueCount:     r.OverdueCount,
			BlockedCount:     r.BlockedCount,
			AvgCycleTimeDays: r.AvgCycleTimeDays,
		}

		// Slack message count — best effort.
		msgCount, err := d.GetUserMessageCount(r.SlackUserID, from, to)
		if err == nil {
			e.SlackMessageCount = msgCount
		}

		// Calendar meeting hours — best effort (may be 0 if calendar not connected).
		hours, err := d.GetUserMeetingHours(r.SlackUserID, from, to)
		if err == nil {
			e.MeetingHours = hours
		}

		e.Signal = computeSignal(e.OpenIssues, e.OverdueCount, e.BlockedCount, e.SlackMessageCount)
		entries = append(entries, e)
	}

	// Sort: overload first, then watch, low, normal. Within same signal, by open_issues DESC.
	sort.Slice(entries, func(i, j int) bool {
		pi, pj := signalPriority(entries[i].Signal), signalPriority(entries[j].Signal)
		if pi != pj {
			return pi < pj
		}
		return entries[i].OpenIssues > entries[j].OpenIssues
	})

	return entries, nil
}
