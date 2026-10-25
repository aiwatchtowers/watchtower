package db

import (
	"fmt"
	"slices"
	"strings"
)

// JiraProjectIssueKeys returns every stored issue key of one account's project.
func (db *DB) JiraProjectIssueKeys(accountID int64, projectKey string) ([]string, error) {
	rows, err := db.Query(`SELECT key FROM jira_issues WHERE account_id = ? AND project_key = ?`, accountID, projectKey)
	if err != nil {
		return nil, fmt.Errorf("listing stored jira keys of account %d project %s: %w", accountID, projectKey, err)
	}
	defer rows.Close()
	var keys []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, fmt.Errorf("scanning stored jira key: %w", err)
		}
		keys = append(keys, k)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating stored jira keys: %w", err)
	}
	return keys, nil
}

// DeleteJiraIssues removes the given issues of one account with their comments,
// changelog, changelog cursor and links, and blanks the text copies of the
// inbox items made from them, in one transaction (IN chunks of 500).
// It returns the number of jira_issues rows deleted.
//
// Jira inbox items carry the bare issue key as channel_id, so an item is left
// as it is while another account still stores a live issue under that key.
// The jira_comments delete trigger marks the issue's KB document; an issue
// without comments leaves the KB through the indexer's per-run reconcile.
func (db *DB) DeleteJiraIssues(accountID int64, keys []string) (int, error) {
	if len(keys) == 0 {
		return 0, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("beginning jira issue delete: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	total := 0
	const chunk = 500
	for start := 0; start < len(keys); start += chunk {
		part := keys[start:min(start+chunk, len(keys))]
		marks := strings.TrimSuffix(strings.Repeat("?,", len(part)), ",")
		args := make([]any, 0, len(part))
		for _, k := range part {
			args = append(args, k)
		}
		withAccount := slices.Concat([]any{accountID}, args)

		//nolint:gosec // G202: only "?" placeholders are concatenated; every value is a bound arg.
		if _, err := tx.Exec(`UPDATE inbox_items SET snippet = '', context = '', raw_text = ''
			WHERE substr(trigger_type, 1, 5) = 'jira_' AND channel_id IN (`+marks+`)
			AND (snippet != '' OR context != '' OR raw_text != '')
			AND NOT EXISTS (SELECT 1 FROM jira_issues o
				WHERE o.key = inbox_items.channel_id AND o.account_id != ? AND o.is_deleted = 0)`,
			slices.Concat(args, []any{accountID})...); err != nil {
			return 0, fmt.Errorf("clearing inbox copies of jira issues for account %d: %w", accountID, err)
		}
		for _, table := range []string{"jira_comments", "jira_issue_changelog", "jira_changelog_sync"} {
			//nolint:gosec // G202: table names are constants and only "?" placeholders are concatenated.
			if _, err := tx.Exec(`DELETE FROM `+table+` WHERE account_id = ? AND issue_key IN (`+marks+`)`,
				withAccount...); err != nil {
				return 0, fmt.Errorf("deleting %s of jira issues for account %d: %w", table, accountID, err)
			}
		}
		//nolint:gosec // G202: only "?" placeholders are concatenated; every value is a bound arg.
		if _, err := tx.Exec(`DELETE FROM jira_issue_links WHERE account_id = ?
			AND (source_key IN (`+marks+`) OR target_key IN (`+marks+`))`,
			slices.Concat(withAccount, args)...); err != nil {
			return 0, fmt.Errorf("deleting links of jira issues for account %d: %w", accountID, err)
		}
		//nolint:gosec // G202: only "?" placeholders are concatenated; every value is a bound arg.
		res, err := tx.Exec(`DELETE FROM jira_issues WHERE account_id = ? AND key IN (`+marks+`)`, withAccount...)
		if err != nil {
			return 0, fmt.Errorf("deleting jira issues for account %d: %w", accountID, err)
		}
		n, _ := res.RowsAffected()
		total += int(n)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing jira issue delete: %w", err)
	}
	return total, nil
}
