package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// Linear reads and floors for the ideas registry's Linear stream (spec
// 2026-10-15-linear-integration-design §6 "ideas"). They mirror the Jira
// stream's IdeasJiraFloor / ListJiraIssuesUpdatedSince / ListJiraCommentsSince
// / OldestFailingJiraProjectSync. Linear stores its timestamps as the API
// returns them ("2006-01-02T15:04:05.000Z", the FormatJiraTime shape), so a
// plain string compare is instant order.

// IdeasLinearFloor returns the ideas registry's per-account Linear pre-digest
// watermark (linear_accounts.ideas_floor) — separate from
// memory_last_extracted_ts. A missing account reads as "".
func (db *DB) IdeasLinearFloor(accountID int64) (string, error) {
	var ts string
	err := db.QueryRow(`SELECT ideas_floor FROM linear_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting ideas linear floor for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetIdeasLinearFloor advances the Linear pre-digest watermark for accountID
// (see IdeasLinearFloor). The pass only moves it past rendered material.
func (db *DB) SetIdeasLinearFloor(accountID int64, ts string) error {
	res, err := db.Exec(`UPDATE linear_accounts SET ideas_floor = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting ideas linear floor for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting ideas linear floor: no linear_accounts row %d", accountID)
	}
	return nil
}

// ListLinearIssuesUpdatedSince returns accountID's non-deleted Linear issues
// with updated_at strictly above sinceISO (and at most beforeISO when set),
// ascending by updated_at, capped at limit. A LIMIT cut inside a group of
// issues sharing one updated_at is extended to the whole group (the
// ListJiraIssuesUpdatedSince boundary drain), because the caller reloads with
// a strict > and would otherwise drop the unloaded members permanently.
func (db *DB) ListLinearIssuesUpdatedSince(accountID int64, sinceISO, beforeISO string, limit int) ([]LinearIssue, error) {
	if limit <= 0 {
		limit = 300
	}
	out, err := db.queryLinearIssuesUpdated(accountID, ">", sinceISO, beforeISO, limit)
	if err != nil || len(out) < limit {
		return out, err
	}
	boundary := out[len(out)-1].UpdatedAt
	full, err := db.queryLinearIssuesUpdated(accountID, "=", boundary, "", -1) // LIMIT -1: unbounded
	if err != nil {
		return nil, err
	}
	i := len(out)
	for i > 0 && out[i-1].UpdatedAt == boundary {
		i--
	}
	return append(out[:i], full...), nil
}

// queryLinearIssuesUpdated runs the window select with op ">" or "=" (never
// user input). ORDER BY ends in id so a same-timestamp group is deterministic.
func (db *DB) queryLinearIssuesUpdated(accountID int64, op, tsArg, beforeISO string, limit int) ([]LinearIssue, error) {
	query := `SELECT ` + linearIssueColumns + ` FROM linear_issues
		WHERE account_id = ? AND is_deleted = 0 AND updated_at ` + op + ` ?`
	args := []any{accountID, tsArg}
	if beforeISO != "" {
		query += ` AND updated_at <= ?`
		args = append(args, beforeISO)
	}
	query += ` ORDER BY updated_at ASC, id ASC LIMIT ?`
	args = append(args, limit)
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing linear issues updated since: %w", err)
	}
	return scanLinearIssues(rows)
}

// linearCommentsPerWindowLimit bounds how many comments one Linear pre-digest
// window loads (the jiraCommentsPerWindowLimit twin).
const linearCommentsPerWindowLimit = 500

// ListLinearCommentsSince returns the comments of the account's issueIDs
// updated at or after sinceISO, oldest first per issue, capped at
// linearCommentsPerWindowLimit.
func (db *DB) ListLinearCommentsSince(accountID int64, issueIDs []string, sinceISO string) ([]LinearComment, error) {
	if len(issueIDs) == 0 {
		return nil, nil
	}
	args := []any{accountID}
	for _, id := range issueIDs {
		args = append(args, id)
	}
	args = append(args, sinceISO, linearCommentsPerWindowLimit)
	rows, err := db.Query(`SELECT account_id, id, issue_id, issue_key, author_id, author_display_name, body_text,
		mentioned_user_ids, created_at, updated_at
		FROM linear_comments WHERE account_id = ? AND issue_id IN (`+sqlPlaceholders(len(issueIDs))+`) AND updated_at >= ?
		ORDER BY issue_id, updated_at, id LIMIT ?`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing linear comments since: %w", err)
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

// OldestFailingLinearTeamSync returns the oldest last_synced_at among the
// account's selected teams whose latest sync attempt failed (last_error is
// cleared by the next success) but which have synced at least once, or ""
// when there is none — the OldestFailingJiraProjectSync rule for Linear (spec
// §5): a cursor over the account's issues must not pass it, since the failing
// team's changes have not reached linear_issues yet.
func (db *DB) OldestFailingLinearTeamSync(accountID int64) (string, error) {
	var oldest sql.NullString
	err := db.QueryRow(`SELECT MIN(s.last_synced_at) FROM linear_sync_state s
		WHERE s.account_id = ? AND s.last_error != '' AND s.last_synced_at != ''
		  AND s.team_id IN (SELECT id FROM linear_teams WHERE account_id = ? AND is_selected = 1)`,
		accountID, accountID).Scan(&oldest)
	if err != nil {
		return "", fmt.Errorf("reading failing linear team syncs for account %d: %w", accountID, err)
	}
	return oldest.String, nil
}
