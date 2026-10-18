package db

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
)

// Linear reads and watermarks for memory's mechanical Linear issue → episode
// builder (spec 2026-10-15-linear-integration-design §6 "memory"), the twins
// of MemoryJiraWatermark / MaxJiraUpdatedUnix / ListJiraIssuesForExtract /
// JiraIssueExists. The watermark is linear_accounts.memory_last_extracted_ts
// (parsed updated_at, unix seconds), one per workspace.

// MemoryLinearWatermark returns the Linear extraction watermark for accountID;
// a missing account reads as 0.
func (db *DB) MemoryLinearWatermark(accountID int64) (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT memory_last_extracted_ts FROM linear_accounts WHERE id = ?`, accountID).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory linear watermark for account %d: %w", accountID, err)
	}
	return ts, nil
}

// SetMemoryLinearWatermark advances the Linear extraction watermark for
// accountID. Callers only move it behind fully-committed episodes (MEM-04).
func (db *DB) SetMemoryLinearWatermark(accountID int64, ts float64) error {
	res, err := db.Exec(`UPDATE linear_accounts SET memory_last_extracted_ts = ? WHERE id = ?`, ts, accountID)
	if err != nil {
		return fmt.Errorf("setting memory linear watermark for account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting memory linear watermark: no linear_accounts row %d", accountID)
	}
	return nil
}

// LinearIssueExists is the linear: scheme's write-time existence check
// (MEM-12): a linear:<KEY> ref resolves iff a non-deleted linear_issues row
// carries that key now or carried it before a team move (previous_keys), so a
// ref minted before the move still resolves. linear_issues is
// migration-guaranteed, so a lookup failure is a genuine error.
func (db *DB) LinearIssueExists(key string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM linear_issues
		WHERE is_deleted = 0 AND (key = ? OR EXISTS (SELECT 1 FROM json_each(linear_issues.previous_keys) WHERE value = ?))
		LIMIT 1`, key, key).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking linear issue %s: %w", key, err)
	}
	return true, nil
}

// LinearExtractIssue is one linear_issues row projected for the mechanical
// issue → episode builder.
type LinearExtractIssue struct {
	AccountID                                    int64
	ID, Key, TeamKey, Title, DescriptionText     string
	StateName, StatusCategory                    string
	Priority                                     int
	AssigneeDisplayName, AssigneeSlackID         string
	CreatorDisplayName, CreatorSlackID           string
	CycleName, ProjectName, DueDate, CompletedAt string
	CanceledAt                                   string
	Estimate                                     sql.NullFloat64
	UpdatedAtRaw                                 string
	UpdatedUnix                                  int64
}

// ListLinearIssuesForExtract returns accountID's non-deleted issues whose
// PARSED updated_at is strictly above sinceUnix, ascending, capped at limit
// with the boundary second drained (the ListJiraIssuesForExtract shape: the
// table is small, so the filter and sort run in Go after the parse).
func (db *DB) ListLinearIssuesForExtract(accountID int64, sinceUnix int64, limit int) ([]LinearExtractIssue, error) {
	rows, err := db.Query(`SELECT li.account_id, li.id, li.key, li.team_key, li.title, li.description_text,
		li.state_name, li.status_category, li.priority, li.assignee_display_name, li.assignee_slack_id,
		li.creator_display_name, li.creator_slack_id,
		COALESCE((SELECT CASE WHEN c.name != '' THEN c.name ELSE 'Cycle ' || c.number END
		          FROM linear_cycles c WHERE c.account_id = li.account_id AND c.id = li.cycle_id), ''),
		COALESCE((SELECT p.name FROM linear_projects p WHERE p.account_id = li.account_id AND p.id = li.project_id), ''),
		li.due_date, li.completed_at, li.canceled_at, li.estimate, li.updated_at
		FROM linear_issues li WHERE li.account_id = ? AND li.is_deleted = 0`, accountID)
	if err != nil {
		return nil, fmt.Errorf("listing linear issues for extract: %w", err)
	}
	defer rows.Close()

	var out []LinearExtractIssue
	for rows.Next() {
		var is LinearExtractIssue
		if err := rows.Scan(&is.AccountID, &is.ID, &is.Key, &is.TeamKey, &is.Title, &is.DescriptionText,
			&is.StateName, &is.StatusCategory, &is.Priority, &is.AssigneeDisplayName, &is.AssigneeSlackID,
			&is.CreatorDisplayName, &is.CreatorSlackID, &is.CycleName, &is.ProjectName,
			&is.DueDate, &is.CompletedAt, &is.CanceledAt, &is.Estimate, &is.UpdatedAtRaw); err != nil {
			return nil, fmt.Errorf("scanning linear issue for extract: %w", err)
		}
		u, ok := ParseJiraTime(is.UpdatedAtRaw)
		if !ok || u <= sinceUnix {
			continue
		}
		is.UpdatedUnix = u
		out = append(out, is)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("linear extract rows: %w", err)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].UpdatedUnix != out[j].UpdatedUnix {
			return out[i].UpdatedUnix < out[j].UpdatedUnix
		}
		return out[i].ID < out[j].ID
	})
	if limit > 0 && len(out) > limit {
		boundary := out[limit-1].UpdatedUnix
		end := limit
		for end < len(out) && out[end].UpdatedUnix == boundary {
			end++
		}
		out = out[:end]
	}
	return out, nil
}

// MaxLinearUpdatedUnix is the no-backfill initializer's bound: the newest
// parsed updated_at among one account's non-deleted issues, 0 when none.
func (db *DB) MaxLinearUpdatedUnix(accountID int64) (int64, error) {
	rows, err := db.Query(`SELECT updated_at FROM linear_issues WHERE account_id = ? AND is_deleted = 0`, accountID)
	if err != nil {
		return 0, fmt.Errorf("scanning linear updated_at for max: %w", err)
	}
	defer rows.Close()
	var maxU int64
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return 0, fmt.Errorf("scanning linear updated_at: %w", err)
		}
		if u, ok := ParseJiraTime(raw); ok && u > maxU {
			maxU = u
		}
	}
	return maxU, rows.Err()
}
