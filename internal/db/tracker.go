package db

import (
	"database/sql"
	"fmt"
)

// TrackerIssue is one row of the tracker_issues view (migration 00120): a Jira
// or Linear issue in tracker-neutral terms. Column names are a contract for
// the consumers (briefing, inbox, day plan).
type TrackerIssue struct {
	Tracker             string
	AccountID           int64
	IssueID             string
	Key                 string
	ProjectKey          string
	Title               string
	DescriptionText     string
	Status              string
	StatusCategory      string
	StatusChangedAt     string
	AssigneeID          string
	AssigneeEmail       string
	AssigneeDisplayName string
	AssigneeSlackID     string
	ReporterID          string
	ReporterDisplayName string
	ReporterSlackID     string
	Priority            string
	PriorityRank        int
	Points              *float64
	DueDate             string
	IterationID         string
	IterationName       string
	ContainerKind       string
	ContainerID         string
	ContainerName       string
	ParentKey           string
	Labels              string
	IsBug               bool
	IsBlocked           bool
	URL                 string
	CreatedAt           string
	UpdatedAt           string
	ResolvedAt          string
	SyncedAt            string
}

// TrackerIssueFilter narrows ListTrackerIssues; zero values mean "any".
type TrackerIssueFilter struct {
	Tracker         string // "jira" | "linear"; "" = both
	AssigneeSlackID string
	OpenOnly        bool // status_category != 'done'
	Limit           int  // 0 = no limit
}

// ListTrackerIssues reads tracker_issues (is_deleted = 0), ordered by
// priority_rank (0 last), then updated_at DESC.
func (db *DB) ListTrackerIssues(f TrackerIssueFilter) ([]TrackerIssue, error) {
	q := `SELECT tracker, account_id, issue_id, key, project_key, title, description_text,
		status, status_category, status_changed_at,
		assignee_id, assignee_email, assignee_display_name, assignee_slack_id,
		reporter_id, reporter_display_name, reporter_slack_id,
		priority, priority_rank, points, due_date,
		iteration_id, iteration_name, container_kind, container_id, container_name, parent_key,
		labels, is_bug, is_blocked, url, created_at, updated_at, resolved_at, synced_at
		FROM tracker_issues WHERE is_deleted = 0`
	var args []any
	if f.Tracker != "" {
		q += ` AND tracker = ?`
		args = append(args, f.Tracker)
	}
	if f.AssigneeSlackID != "" {
		q += ` AND assignee_slack_id = ?`
		args = append(args, f.AssigneeSlackID)
	}
	if f.OpenOnly {
		q += ` AND status_category != 'done'`
	}
	q += ` ORDER BY CASE WHEN priority_rank = 0 THEN 99 ELSE priority_rank END, updated_at DESC`
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list tracker issues: %w", err)
	}
	defer rows.Close()
	var out []TrackerIssue
	for rows.Next() {
		var t TrackerIssue
		var points sql.NullFloat64
		if err := rows.Scan(&t.Tracker, &t.AccountID, &t.IssueID, &t.Key, &t.ProjectKey, &t.Title, &t.DescriptionText,
			&t.Status, &t.StatusCategory, &t.StatusChangedAt,
			&t.AssigneeID, &t.AssigneeEmail, &t.AssigneeDisplayName, &t.AssigneeSlackID,
			&t.ReporterID, &t.ReporterDisplayName, &t.ReporterSlackID,
			&t.Priority, &t.PriorityRank, &points, &t.DueDate,
			&t.IterationID, &t.IterationName, &t.ContainerKind, &t.ContainerID, &t.ContainerName, &t.ParentKey,
			&t.Labels, &t.IsBug, &t.IsBlocked, &t.URL, &t.CreatedAt, &t.UpdatedAt, &t.ResolvedAt, &t.SyncedAt); err != nil {
			return nil, fmt.Errorf("scan tracker issue: %w", err)
		}
		if points.Valid {
			v := points.Float64
			t.Points = &v
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
