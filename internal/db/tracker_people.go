package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Tracker-neutral per-person reads for the people cards (spec
// 2026-10-15-linear-integration-design §6 "meeting prep, people cards"):
// delivery stats and resolved issues over tracker_issues, so Jira and Linear
// work both count. A Linear issue's resolved_at is its completed (or canceled)
// time, its points its estimate.

// GetTrackerDeliveryStats returns delivery metrics for a Slack user in a date
// range, across both trackers — the GetJiraDeliveryStats twin. Components are
// Jira-only (Linear has none) and still read from jira_issues.
func (db *DB) GetTrackerDeliveryStats(slackID string, from, to string) (*DeliveryStats, error) {
	stats := &DeliveryStats{}
	const closed = `assignee_slack_id = ? AND status_category = 'done' AND resolved_at >= ? AND resolved_at <= ? AND is_deleted = 0`

	var avgCycle, points sql.NullFloat64
	err := db.QueryRow(`SELECT COUNT(*),
			AVG(CASE WHEN resolved_at != '' THEN julianday(resolved_at) - julianday(created_at) END),
			COALESCE(SUM(points), 0)
		FROM tracker_issues WHERE `+closed, slackID, from, to).Scan(&stats.IssuesClosed, &avgCycle, &points)
	if err != nil {
		return nil, fmt.Errorf("tracker delivery: closed issues: %w", err)
	}
	if avgCycle.Valid {
		stats.AvgCycleTimeDays = avgCycle.Float64
	}
	if points.Valid {
		stats.StoryPointsCompleted = points.Float64
	}

	today := time.Now().Format("2006-01-02")
	err = db.QueryRow(`SELECT COUNT(*),
			COUNT(CASE WHEN due_date != '' AND due_date < ? THEN 1 END)
		FROM tracker_issues WHERE assignee_slack_id = ? AND status_category != 'done' AND is_deleted = 0`,
		today, slackID).Scan(&stats.OpenIssues, &stats.OverdueIssues)
	if err != nil {
		return nil, fmt.Errorf("tracker delivery: open issues: %w", err)
	}

	stats.Components, err = db.distinctJSONValues(`SELECT DISTINCT components FROM jira_issues
		WHERE `+closed+` AND components != '[]'`, slackID, from, to)
	if err != nil {
		return nil, fmt.Errorf("tracker delivery: components: %w", err)
	}
	stats.Labels, err = db.distinctJSONValues(`SELECT DISTINCT labels FROM tracker_issues
		WHERE `+closed+` AND labels != '[]'`, slackID, from, to)
	if err != nil {
		return nil, fmt.Errorf("tracker delivery: labels: %w", err)
	}
	return stats, nil
}

// distinctJSONValues unions the string arrays a one-column JSON-array query
// returns; a malformed row contributes nothing.
func (db *DB) distinctJSONValues(query string, args ...any) ([]string, error) {
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	seen := map[string]bool{}
	var out []string
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var arr []string
		if json.Unmarshal([]byte(raw), &arr) != nil {
			continue
		}
		for _, v := range arr {
			if !seen[v] {
				seen[v] = true
				out = append(out, v)
			}
		}
	}
	return out, rows.Err()
}

// DeliveredIssue is one resolved issue of a person, for the people card's
// accomplishments list.
type DeliveredIssue struct {
	Tracker, Key, Title, ResolvedAt string
}

// GetTrackerResolvedIssuesForUser returns a Slack user's issues resolved in
// [from, to], newest first, at most limit — both trackers.
func (db *DB) GetTrackerResolvedIssuesForUser(slackID, from, to string, limit int) ([]DeliveredIssue, error) {
	rows, err := db.Query(`SELECT tracker, key, title, resolved_at FROM tracker_issues
		WHERE assignee_slack_id = ? AND status_category = 'done' AND is_deleted = 0
			AND resolved_at >= ? AND resolved_at <= ?
		ORDER BY resolved_at DESC
		LIMIT ?`, slackID, from, to, limit)
	if err != nil {
		return nil, fmt.Errorf("querying resolved tracker issues for user %s: %w", slackID, err)
	}
	defer rows.Close()
	var out []DeliveredIssue
	for rows.Next() {
		var d DeliveredIssue
		if err := rows.Scan(&d.Tracker, &d.Key, &d.Title, &d.ResolvedAt); err != nil {
			return nil, fmt.Errorf("scanning resolved tracker issue: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
