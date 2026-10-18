package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// LinearIssueDossier is one Linear issue as the developer-surface tools
// (get_task_context, find_experts) read it: tracker_issues' neutral fields plus
// the issue's previous keys, so Slack links and registry mentions written
// under a key the issue had before a team move are still found.
type LinearIssueDossier struct {
	AccountID       int64
	IssueID         string
	Key             string
	PreviousKeys    []string
	Title           string
	Description     string
	Status          string
	Priority        string
	AssigneeName    string
	AssigneeSlackID string
	ReporterName    string
	ReporterSlackID string
	IterationName   string
	UpdatedAt       string
}

// Keys returns the issue's current key followed by its previous ones.
func (d LinearIssueDossier) Keys() []string {
	return append([]string{d.Key}, d.PreviousKeys...)
}

// GetLinearIssueDossier finds a non-deleted Linear issue by its current key or
// a previous one (lowest account, then id, when two workspaces share a key),
// reading its neutral fields from tracker_issues. (nil, nil) when none.
func (db *DB) GetLinearIssueDossier(key string) (*LinearIssueDossier, error) {
	var d LinearIssueDossier
	var prev string
	err := db.QueryRow(`SELECT ti.account_id, ti.issue_id, ti.key, li.previous_keys, ti.title, ti.description_text,
			ti.status, ti.priority, ti.assignee_display_name, ti.assignee_slack_id,
			ti.reporter_display_name, ti.reporter_slack_id, ti.iteration_name, ti.updated_at
		FROM linear_issues li
		JOIN tracker_issues ti ON ti.tracker = 'linear' AND ti.account_id = li.account_id AND ti.issue_id = li.id
		WHERE li.is_deleted = 0
		  AND (li.key = ? OR EXISTS (SELECT 1 FROM json_each(li.previous_keys) WHERE value = ?))
		ORDER BY li.account_id, li.id LIMIT 1`, key, key).
		Scan(&d.AccountID, &d.IssueID, &d.Key, &prev, &d.Title, &d.Description, &d.Status, &d.Priority,
			&d.AssigneeName, &d.AssigneeSlackID, &d.ReporterName, &d.ReporterSlackID, &d.IterationName, &d.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting linear issue dossier %s: %w", key, err)
	}
	d.PreviousKeys = parseJSONList(prev)
	return &d, nil
}

// GetTrackerPersonSlackID maps a tracker user id (an Atlassian account id or a
// Linear user id) to its Slack user id through tracker_people; "" when the
// person is unknown or unmapped.
func (db *DB) GetTrackerPersonSlackID(tracker, userID string) (string, error) {
	var slackID string
	err := db.QueryRow(`SELECT slack_user_id FROM tracker_people WHERE tracker = ? AND user_id = ? LIMIT 1`,
		tracker, userID).Scan(&slackID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("mapping %s user %s to slack: %w", tracker, userID, err)
	}
	return slackID, nil
}
