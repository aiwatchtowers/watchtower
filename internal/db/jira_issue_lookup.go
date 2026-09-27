package db

import (
	"database/sql"
	"fmt"
)

// GetJiraIssue returns one mirrored issue by its composite key, nil when the
// account's mirror has no such row. Unlike GetJiraIssueByKey it never picks
// an arbitrary site for a key two sites share.
func (db *DB) GetJiraIssue(accountID int64, key string) (*JiraIssue, error) {
	row := db.QueryRow(`SELECT `+jiraIssueColumns+` FROM jira_issues WHERE account_id = ? AND key = ?`, accountID, key)
	issue, err := scanJiraIssue(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scanning jira issue %d/%s: %w", accountID, key, err)
	}
	return &issue, nil
}

// JiraAccountIDsForIssueKey lists the enabled, non-removed accounts whose
// mirror holds a live row for key — the site a write to that key targets.
func (db *DB) JiraAccountIDsForIssueKey(key string) ([]int64, error) {
	rows, err := db.Query(`SELECT ji.account_id FROM jira_issues ji
		JOIN jira_accounts ja ON ja.id = ji.account_id
		WHERE ji.key = ? AND ji.is_deleted = 0 AND ja.enabled = 1 AND ja.status != 'removed'
		ORDER BY ji.account_id`, key)
	if err != nil {
		return nil, fmt.Errorf("querying accounts for jira issue %s: %w", key, err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning account id for jira issue %s: %w", key, err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
