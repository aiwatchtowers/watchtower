package db

import "fmt"

// LinkedLinearIssue is a Linear issue a track links to through
// issue_slack_links, as the tracks CLI lists it.
type LinkedLinearIssue struct {
	Key, Title, Status, StatusCategory, AssigneeDisplayName, DueDate, URL string
}

// GetLinearIssuesForTracks returns the non-deleted Linear issues linked to each
// of trackIDs (tracker 'linear' links, matched on the issue's current key or a
// previous one), newest update first per track; tracks with none are absent.
// The Linear twin of GetJiraIssuesForTracks.
func (db *DB) GetLinearIssuesForTracks(trackIDs []int) (map[int][]LinkedLinearIssue, error) {
	if len(trackIDs) == 0 {
		return nil, nil
	}
	args := make([]any, len(trackIDs))
	for i, id := range trackIDs {
		args[i] = id
	}
	rows, err := db.Query(`SELECT DISTINCT l.track_id, li.id, li.key, li.title, li.state_name, li.status_category,
			li.assignee_display_name, li.due_date, li.url, li.updated_at
		FROM issue_slack_links l
		JOIN linear_issues li ON li.is_deleted = 0
		  AND (li.key = l.issue_key OR EXISTS (SELECT 1 FROM json_each(li.previous_keys) WHERE value = l.issue_key))
		WHERE l.tracker = 'linear' AND l.track_id IN (`+sqlPlaceholders(len(trackIDs))+`)
		ORDER BY l.track_id, li.updated_at DESC`, args...)
	if err != nil {
		return nil, fmt.Errorf("querying linear issues for tracks: %w", err)
	}
	defer rows.Close()
	out := map[int][]LinkedLinearIssue{}
	seen := map[string]bool{}
	for rows.Next() {
		var trackID int
		var id, updatedAt string
		var is LinkedLinearIssue
		if err := rows.Scan(&trackID, &id, &is.Key, &is.Title, &is.Status, &is.StatusCategory,
			&is.AssigneeDisplayName, &is.DueDate, &is.URL, &updatedAt); err != nil {
			return nil, fmt.Errorf("scanning linear issue for track: %w", err)
		}
		k := fmt.Sprintf("%d|%s", trackID, id)
		if seen[k] { // linked under two of its keys
			continue
		}
		seen[k] = true
		out[trackID] = append(out[trackID], is)
	}
	return out, rows.Err()
}
