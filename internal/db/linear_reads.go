package db

import (
	"fmt"
	"strings"
)

// LinearIssueFilter narrows ListLinearIssues. A zero field does not filter;
// AccountIDs empty means every account. AssigneeIDs and AssigneeEmail are
// alternatives (the tool sets at most one): AssigneeIDs wins when both are set.
type LinearIssueFilter struct {
	AccountIDs    []int64
	TeamKey       string
	StateName     string
	StateType     string
	AssigneeIDs   []string
	AssigneeEmail string
	// CreatedAfter is a UTC "2006-01-02T15:04:05Z" instant; issues created at
	// or after it match. Compared through strftime, so stored values with
	// fractional seconds order correctly.
	CreatedAfter string
	Limit        int
}

// ListLinearIssues returns the non-deleted issues matching f, newest created
// first. TeamKey is the issue's current team; StateName and AssigneeEmail
// match case-insensitively.
func (db *DB) ListLinearIssues(f LinearIssueFilter) ([]LinearIssue, error) {
	q := `SELECT account_id, id, key, previous_keys, team_id, team_key, title,
		description_text, state_name, state_type, status_category, state_changed_at, assignee_id, assignee_email,
		assignee_display_name, creator_id, creator_email, creator_display_name, priority, estimate, due_date,
		cycle_id, project_id, parent_id, labels, url, created_at, updated_at, completed_at, canceled_at, raw_json,
		is_deleted
		FROM linear_issues WHERE is_deleted = 0`
	var args []any
	if len(f.AccountIDs) > 0 {
		q += ` AND account_id IN (` + sqlPlaceholders(len(f.AccountIDs)) + `)`
		for _, id := range f.AccountIDs {
			args = append(args, id)
		}
	}
	if f.TeamKey != "" {
		q += ` AND team_key = ?`
		args = append(args, f.TeamKey)
	}
	if f.StateName != "" {
		q += ` AND state_name = ? COLLATE NOCASE`
		args = append(args, f.StateName)
	}
	if f.StateType != "" {
		q += ` AND state_type = ?`
		args = append(args, f.StateType)
	}
	switch {
	case len(f.AssigneeIDs) > 0:
		q += ` AND assignee_id IN (` + sqlPlaceholders(len(f.AssigneeIDs)) + `)`
		for _, id := range f.AssigneeIDs {
			args = append(args, id)
		}
	case f.AssigneeEmail != "":
		q += ` AND assignee_email = ? COLLATE NOCASE`
		args = append(args, f.AssigneeEmail)
	}
	if f.CreatedAfter != "" {
		q += ` AND strftime('%Y-%m-%dT%H:%M:%SZ', created_at) >= ?`
		args = append(args, f.CreatedAfter)
	}
	q += ` ORDER BY strftime('%Y-%m-%dT%H:%M:%SZ', created_at) DESC, account_id, id`
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing linear issues: %w", err)
	}
	defer rows.Close()
	var out []LinearIssue
	for rows.Next() {
		var i LinearIssue
		var prev, labels string
		if err := rows.Scan(&i.AccountID, &i.ID, &i.Key, &prev, &i.TeamID, &i.TeamKey, &i.Title,
			&i.DescriptionText, &i.StateName, &i.StateType, &i.StatusCategory, &i.StateChangedAt, &i.AssigneeID, &i.AssigneeEmail,
			&i.AssigneeDisplayName, &i.CreatorID, &i.CreatorEmail, &i.CreatorDisplayName, &i.Priority, &i.Estimate, &i.DueDate,
			&i.CycleID, &i.ProjectID, &i.ParentID, &labels, &i.URL, &i.CreatedAt, &i.UpdatedAt, &i.CompletedAt, &i.CanceledAt, &i.RawJSON,
			&i.IsDeleted); err != nil {
			return nil, fmt.Errorf("scanning linear issue: %w", err)
		}
		i.PreviousKeys = parseJSONList(prev)
		i.Labels = parseJSONList(labels)
		out = append(out, i)
	}
	return out, rows.Err()
}

func sqlPlaceholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// ListLinearComments returns an issue's comments, oldest first.
func (db *DB) ListLinearComments(accountID int64, issueID string) ([]LinearComment, error) {
	rows, err := db.Query(`SELECT account_id, id, issue_id, issue_key, author_id, author_display_name, body_text,
		mentioned_user_ids, created_at, updated_at
		FROM linear_comments WHERE account_id = ? AND issue_id = ? ORDER BY created_at, id`, accountID, issueID)
	if err != nil {
		return nil, fmt.Errorf("listing linear comments: %w", err)
	}
	defer rows.Close()
	var out []LinearComment
	for rows.Next() {
		var c LinearComment
		var mentioned string
		if err := rows.Scan(&c.AccountID, &c.ID, &c.IssueID, &c.IssueKey, &c.AuthorID, &c.AuthorDisplayName,
			&c.BodyText, &mentioned, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning linear comment: %w", err)
		}
		c.MentionedUserIDs = parseJSONList(mentioned)
		out = append(out, c)
	}
	return out, rows.Err()
}

// ListLinearHistory returns the status and assignee changes of the issues,
// oldest first per issue.
func (db *DB) ListLinearHistory(accountID int64, issueIDs []string) ([]LinearHistoryEntry, error) {
	if len(issueIDs) == 0 {
		return nil, nil
	}
	args := []any{accountID}
	for _, id := range issueIDs {
		args = append(args, id)
	}
	rows, err := db.Query(`SELECT account_id, id, field, issue_id, from_value, from_string, to_value, to_string,
		actor_id, actor_display_name, changed_at
		FROM linear_issue_history WHERE account_id = ? AND issue_id IN (`+sqlPlaceholders(len(issueIDs))+`)
		ORDER BY issue_id, changed_at, id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing linear history: %w", err)
	}
	defer rows.Close()
	var out []LinearHistoryEntry
	for rows.Next() {
		var h LinearHistoryEntry
		if err := rows.Scan(&h.AccountID, &h.ID, &h.Field, &h.IssueID, &h.FromValue, &h.FromString, &h.ToValue,
			&h.ToString, &h.ActorID, &h.ActorDisplayName, &h.ChangedAt); err != nil {
			return nil, fmt.Errorf("scanning linear history: %w", err)
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// ListLinearCycles returns a team's cycles, newest start first.
func (db *DB) ListLinearCycles(accountID int64, teamID string) ([]LinearCycle, error) {
	rows, err := db.Query(`SELECT account_id, id, team_id, number, name, starts_at, ends_at, completed_at, progress
		FROM linear_cycles WHERE account_id = ? AND team_id = ? ORDER BY starts_at DESC, id`, accountID, teamID)
	if err != nil {
		return nil, fmt.Errorf("listing linear cycles: %w", err)
	}
	defer rows.Close()
	var out []LinearCycle
	for rows.Next() {
		var c LinearCycle
		if err := rows.Scan(&c.AccountID, &c.ID, &c.TeamID, &c.Number, &c.Name, &c.StartsAt, &c.EndsAt,
			&c.CompletedAt, &c.Progress); err != nil {
			return nil, fmt.Errorf("scanning linear cycle: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
