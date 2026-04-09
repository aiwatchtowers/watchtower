package jira

import (
	"sort"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// EpicProgressEntry holds computed progress and forecast for a single epic.
type EpicProgressEntry struct {
	EpicKey          string
	EpicName         string // summary of the epic issue from jira_issues
	TotalIssues      int
	DoneIssues       int
	InProgressIssues int
	ProgressPct      float64 // done/total * 100
	WeeklyDeltaPct   float64 // resolved this week / total * 100
	StatusBadge      string  // "on_track", "at_risk", "behind"
	ForecastWeeks    float64 // (total - done) / velocity_per_week
	VelocityPerWeek  float64 // resolved last 28 days / 4
}

// minEpicIssues is the minimum number of child issues for an epic to be included.
const minEpicIssues = 3

// maxForecastWeeks is used when velocity is zero (effectively infinite).
const maxForecastWeeks = 999.0

// ComputeEpicProgress calculates progress, velocity, forecast and status for
// all epics that have at least minEpicIssues child issues.
// Returns nil, nil when the epic_progress feature is disabled.
func ComputeEpicProgress(database *db.DB, cfg *config.Config, now time.Time) ([]EpicProgressEntry, error) {
	if !IsFeatureEnabled(cfg, "epic_progress") {
		return nil, nil
	}

	weekAgo := now.AddDate(0, 0, -7).Format(time.RFC3339)
	fourWeeksAgo := now.AddDate(0, 0, -28).Format(time.RFC3339)

	aggs, err := database.GetJiraEpicAggregates(weekAgo, fourWeeksAgo)
	if err != nil {
		return nil, err
	}

	if len(aggs) == 0 {
		return nil, nil
	}

	// Collect epic keys for bulk name lookup.
	epicKeys := make([]string, 0, len(aggs))
	for _, a := range aggs {
		epicKeys = append(epicKeys, a.EpicKey)
	}

	epicIssues, err := database.GetJiraIssuesByKeysMap(epicKeys)
	if err != nil {
		return nil, err
	}

	var entries []EpicProgressEntry
	for _, a := range aggs {
		if a.Total < minEpicIssues {
			continue
		}

		progressPct := float64(a.Done) / float64(a.Total) * 100
		weeklyDelta := float64(a.ResolvedLastWeek) / float64(a.Total) * 100
		velocity := float64(a.ResolvedLast4W) / 4.0

		var forecast float64
		remaining := float64(a.Total - a.Done)
		if velocity > 0 {
			forecast = remaining / velocity
		} else {
			forecast = maxForecastWeeks
		}

		badge := computeStatusBadge(a, velocity)

		epicName := ""
		if issue, ok := epicIssues[a.EpicKey]; ok {
			epicName = issue.Summary
		}

		entries = append(entries, EpicProgressEntry{
			EpicKey:          a.EpicKey,
			EpicName:         epicName,
			TotalIssues:      a.Total,
			DoneIssues:       a.Done,
			InProgressIssues: a.InProgress,
			ProgressPct:      progressPct,
			WeeklyDeltaPct:   weeklyDelta,
			StatusBadge:      badge,
			ForecastWeeks:    forecast,
			VelocityPerWeek:  velocity,
		})
	}

	// Sort: at_risk/behind first, then by progress_pct ASC.
	sort.Slice(entries, func(i, j int) bool {
		oi := badgeOrder(entries[i].StatusBadge)
		oj := badgeOrder(entries[j].StatusBadge)
		if oi != oj {
			return oi < oj
		}
		return entries[i].ProgressPct < entries[j].ProgressPct
	})

	return entries, nil
}

// computeStatusBadge determines the status badge based on velocity and weekly progress.
//
// Logic:
//   - behind: velocity == 0 and there are remaining issues, OR no progress this week and epic not done
//   - at_risk: velocity > 0 but weekly resolved < expected weekly rate (total / (total-done) adjusted)
//   - on_track: healthy pace
func computeStatusBadge(a db.EpicAggRow, velocity float64) string {
	remaining := a.Total - a.Done
	if remaining == 0 {
		return "on_track" // epic is complete
	}

	if velocity == 0 {
		return "behind"
	}

	// Expected weekly rate: to finish the remaining items at current velocity,
	// we compare actual weekly progress to velocity.
	// If resolved this week >= velocity (i.e. pace is at or above average), it's on track.
	// If resolved this week > 0 but below velocity, it's at risk.
	// If nothing resolved this week, it's behind.
	if a.ResolvedLastWeek == 0 {
		return "behind"
	}

	if float64(a.ResolvedLastWeek) < velocity {
		return "at_risk"
	}

	return "on_track"
}

// badgeOrder returns sort priority (lower = first).
func badgeOrder(badge string) int {
	switch badge {
	case "behind":
		return 0
	case "at_risk":
		return 1
	case "on_track":
		return 2
	default:
		return 3
	}
}
