package db

import "fmt"

// GetKnownLinearTeamKeys returns the distinct Linear team keys the workspace
// knows — every synced team plus the team key of every stored issue — the
// Linear half of the issue-key detector's known prefixes (GetKnownProjectKeys
// is the Jira half).
func (db *DB) GetKnownLinearTeamKeys() ([]string, error) {
	rows, err := db.Query(`SELECT key FROM linear_teams WHERE key != ''
		UNION SELECT team_key FROM linear_issues WHERE team_key != ''`)
	if err != nil {
		return nil, fmt.Errorf("querying known linear team keys: %w", err)
	}
	defer rows.Close()

	var keys []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, fmt.Errorf("scanning linear team key: %w", err)
		}
		keys = append(keys, k)
	}
	return keys, rows.Err()
}
