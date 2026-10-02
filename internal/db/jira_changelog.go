package db

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// JiraChangelogItem is one changed field of one Jira change history
// (jira_issue_changelog). For Field "status" the *Value fields carry the
// status id and the *String fields its name; for "assignee" the Atlassian
// account id and the display name.
type JiraChangelogItem struct {
	AccountID         int64
	IssueKey          string
	HistoryID         string
	Field             string
	FromValue         string
	FromString        string
	ToValue           string
	ToString          string
	AuthorAccountID   string
	AuthorDisplayName string
	ChangedAt         string
}

// JiraChangelogDue is an issue whose stored changelog is missing or older
// than its current updated_at.
type JiraChangelogDue struct {
	Key       string
	ID        string
	UpdatedAt string
}

// JiraLinkedIssue is a slim snapshot of an issue linked from a synced issue
// that is not itself in jira_issues (jira_linked_issues). FetchError is set
// for a key the site would not return.
type JiraLinkedIssue struct {
	AccountID           int64
	Key                 string
	ID                  string
	ProjectKey          string
	Summary             string
	IssueType           string
	Status              string
	StatusCategory      string
	AssigneeAccountID   string
	AssigneeDisplayName string
	CreatedAt           string
	UpdatedAt           string
	ResolvedAt          string
	FetchError          string
	SyncedAt            string
}

// JiraIssueHistory is one issue's full stored changelog and the updated_at
// it belongs to.
type JiraIssueHistory struct {
	Key       string
	UpdatedAt string
	Items     []JiraChangelogItem
}

// ReplaceJiraIssueChangelogs replaces each issue's stored changelog with its
// Items and stamps its cursor at its UpdatedAt, all in one transaction: the
// API returns an issue's whole (field-filtered) history, so a batch lands
// whole with its cursors or leaves everything as it was and the next pass
// retries.
func (db *DB) ReplaceJiraIssueChangelogs(accountID int64, histories []JiraIssueHistory) error {
	if len(histories) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning changelog write: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	syncedAt := FormatJiraTime(time.Now())
	for _, h := range histories {
		if _, err := tx.Exec(`DELETE FROM jira_issue_changelog WHERE account_id = ? AND issue_key = ?`, accountID, h.Key); err != nil {
			return fmt.Errorf("clearing changelog of %s: %w", h.Key, err)
		}
		for _, it := range h.Items {
			if _, err := tx.Exec(`INSERT OR REPLACE INTO jira_issue_changelog
				(account_id, issue_key, history_id, field, from_value, from_string, to_value, to_string,
				 author_account_id, author_display_name, changed_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				accountID, h.Key, it.HistoryID, it.Field, it.FromValue, it.FromString, it.ToValue, it.ToString,
				it.AuthorAccountID, it.AuthorDisplayName, it.ChangedAt); err != nil {
				return fmt.Errorf("inserting changelog %s/%s: %w", h.Key, it.HistoryID, err)
			}
		}
		if _, err := tx.Exec(`INSERT INTO jira_changelog_sync (account_id, issue_key, issue_updated_at, synced_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(account_id, issue_key) DO UPDATE SET
				issue_updated_at = excluded.issue_updated_at, synced_at = excluded.synced_at`,
			accountID, h.Key, h.UpdatedAt, syncedAt); err != nil {
			return fmt.Errorf("stamping changelog cursor of %s: %w", h.Key, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing changelog write: %w", err)
	}
	return nil
}

// ListJiraChangelogDue returns up to limit of the account's issues whose
// changelog is due — no cursor, or a cursor at another updated_at — newest
// updated_at first, so fresh changes are fetched ahead of the backfill.
// Board issues (not deleted) and fetched linked issues (no fetch_error, not
// also a board issue) both qualify.
func (db *DB) ListJiraChangelogDue(accountID int64, limit int) ([]JiraChangelogDue, error) {
	rows, err := db.Query(`
		SELECT i.key, i.id, i.updated_at FROM (
			SELECT key, id, updated_at FROM jira_issues
			WHERE account_id = ? AND is_deleted = 0 AND id != ''
			UNION ALL
			SELECT l.key, l.id, l.updated_at FROM jira_linked_issues l
			WHERE l.account_id = ? AND l.fetch_error = '' AND l.id != ''
			  AND NOT EXISTS (SELECT 1 FROM jira_issues b WHERE b.account_id = l.account_id AND b.key = l.key AND b.is_deleted = 0)
		) i
		LEFT JOIN jira_changelog_sync c ON c.account_id = ? AND c.issue_key = i.key
		WHERE c.issue_key IS NULL OR c.issue_updated_at != i.updated_at
		ORDER BY i.updated_at DESC, i.key
		LIMIT ?`, accountID, accountID, accountID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing due jira changelogs: %w", err)
	}
	defer rows.Close()
	var out []JiraChangelogDue
	for rows.Next() {
		var d JiraChangelogDue
		if err := rows.Scan(&d.Key, &d.ID, &d.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning due jira changelog: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// liveLinkTargets is the account's link targets that a board issue (not
// deleted) points at: the keys the linked-issue sync is responsible for.
const liveLinkTargets = `SELECT k.target_key FROM jira_issue_links k
	JOIN jira_issues s ON s.account_id = k.account_id AND s.key = k.source_key AND s.is_deleted = 0
	WHERE k.account_id = ?`

// PruneJiraLinkedIssues drops the account's linked-issue rows that are no
// longer needed: a key that is now a board issue (its board got selected —
// its changelog and cursor stay, they belong to the same issue), and a key no
// board issue links to any more (its changelog and cursor go with it). The
// keys are read before the write transaction opens, so the lock is held only
// for the deletes. Returns the number of linked rows removed.
func (db *DB) PruneJiraLinkedIssues(accountID int64) (int64, error) {
	drop, unlinked, err := db.linkedIssuesToPrune(accountID)
	if err != nil {
		return 0, err
	}
	if len(drop) == 0 {
		return 0, nil
	}

	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("beginning linked-issue prune: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed
	dropJSON, _ := json.Marshal(drop)
	unlinkedJSON, _ := json.Marshal(unlinked)
	if _, err := tx.Exec(`DELETE FROM jira_issue_changelog WHERE account_id = ? AND issue_key IN (SELECT value FROM json_each(?))`,
		accountID, string(unlinkedJSON)); err != nil {
		return 0, fmt.Errorf("pruning changelog of unlinked issues: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM jira_changelog_sync WHERE account_id = ? AND issue_key IN (SELECT value FROM json_each(?))`,
		accountID, string(unlinkedJSON)); err != nil {
		return 0, fmt.Errorf("pruning changelog cursors of unlinked issues: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM jira_linked_issues WHERE account_id = ? AND key IN (SELECT value FROM json_each(?))`,
		accountID, string(dropJSON)); err != nil {
		return 0, fmt.Errorf("pruning linked issues: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing linked-issue prune: %w", err)
	}
	return int64(len(drop)), nil
}

// linkedIssuesToPrune returns the linked keys to drop, and the subset of them
// no board issue links to any more (whose history goes too).
func (db *DB) linkedIssuesToPrune(accountID int64) (drop, unlinked []string, err error) {
	rows, err := db.Query(`SELECT l.key,
			EXISTS (SELECT 1 FROM jira_issues b WHERE b.account_id = l.account_id AND b.key = l.key AND b.is_deleted = 0)
		FROM jira_linked_issues l
		WHERE l.account_id = ?
		  AND (l.key NOT IN (`+liveLinkTargets+`)
		    OR EXISTS (SELECT 1 FROM jira_issues b WHERE b.account_id = l.account_id AND b.key = l.key AND b.is_deleted = 0))`,
		accountID, accountID)
	if err != nil {
		return nil, nil, fmt.Errorf("listing linked issues to prune: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		var onBoard bool
		if err := rows.Scan(&key, &onBoard); err != nil {
			return nil, nil, fmt.Errorf("scanning linked issue to prune: %w", err)
		}
		drop = append(drop, key)
		if !onBoard {
			unlinked = append(unlinked, key)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("listing linked issues to prune: %w", err)
	}
	return drop, unlinked, nil
}

// ListJiraLinkedCandidates returns up to limit keys that board issues of the
// account link to and that are not board issues themselves: never-fetched
// keys first, then the longest-unrefreshed ones, so every linked issue is
// revisited in turn under a per-pass cap.
func (db *DB) ListJiraLinkedCandidates(accountID int64, limit int) ([]string, error) {
	rows, err := db.Query(`
		SELECT t.key FROM (
			SELECT DISTINCT target_key AS key FROM (`+liveLinkTargets+`) lt
			WHERE NOT EXISTS (SELECT 1 FROM jira_issues i WHERE i.account_id = ? AND i.key = lt.target_key AND i.is_deleted = 0)
		) t
		LEFT JOIN jira_linked_issues l ON l.account_id = ? AND l.key = t.key
		ORDER BY COALESCE(l.synced_at, '') ASC, t.key
		LIMIT ?`, accountID, accountID, accountID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing linked jira issues: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, fmt.Errorf("scanning linked jira issue: %w", err)
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// UpsertJiraLinkedIssues writes linked-issue snapshots (including rows that
// only record a FetchError) in one transaction.
func (db *DB) UpsertJiraLinkedIssues(issues []JiraLinkedIssue) error {
	if len(issues) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning linked-issue upsert: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	for _, l := range issues {
		if _, err := tx.Exec(`INSERT INTO jira_linked_issues
			(account_id, key, id, project_key, summary, issue_type, status, status_category,
			 assignee_account_id, assignee_display_name, created_at, updated_at, resolved_at, fetch_error, synced_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(account_id, key) DO UPDATE SET
				id = excluded.id, project_key = excluded.project_key, summary = excluded.summary,
				issue_type = excluded.issue_type, status = excluded.status, status_category = excluded.status_category,
				assignee_account_id = excluded.assignee_account_id, assignee_display_name = excluded.assignee_display_name,
				created_at = excluded.created_at, updated_at = excluded.updated_at, resolved_at = excluded.resolved_at,
				fetch_error = excluded.fetch_error, synced_at = excluded.synced_at`,
			l.AccountID, l.Key, l.ID, l.ProjectKey, l.Summary, l.IssueType, l.Status, l.StatusCategory,
			l.AssigneeAccountID, l.AssigneeDisplayName, l.CreatedAt, l.UpdatedAt, l.ResolvedAt, l.FetchError, l.SyncedAt); err != nil {
			return fmt.Errorf("upserting linked jira issue %s: %w", l.Key, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing linked-issue upsert: %w", err)
	}
	return nil
}

// JiraHistoryIssue is an issue as the status-history tools see it: a board
// issue (Source "board") or a linked issue from another board ("linked"),
// with the updated_at its stored changelog belongs to (ChangelogUpdatedAt,
// "" when none was fetched yet).
type JiraHistoryIssue struct {
	AccountID           int64
	Key                 string
	Source              string
	ProjectKey          string
	BoardID             int
	Summary             string
	Status              string
	StatusCategory      string
	AssigneeAccountID   string
	AssigneeDisplayName string
	CreatedAt           string
	UpdatedAt           string
	ChangelogUpdatedAt  string
}

// JiraHistoryFilter selects the issues of ListJiraHistoryIssues. Keys,
// BoardID and ProjectKey narrow the board issues (none = every board issue);
// explicit Keys also match linked issues. IncludeLinked adds the issues the
// selected ones link to. ActiveSince, when set, drops issues in a done
// category whose last update is before it. AccountID 0 means every account.
type JiraHistoryFilter struct {
	AccountID     int64
	Keys          []string
	BoardID       int
	ProjectKey    string
	IncludeLinked bool
	ActiveSince   string
}

// historyIssueSelect is the union both history-issue queries read; the
// caller appends WHERE clauses over its columns.
const historyIssueSelect = `SELECT h.account_id, h.key, h.source, h.project_key, h.board_id, h.summary, h.status,
		h.status_category, h.assignee_account_id, h.assignee_display_name, h.created_at, h.updated_at,
		COALESCE(c.issue_updated_at, '')
	FROM (
		SELECT account_id, key, 'board' AS source, project_key, COALESCE(board_id, 0) AS board_id, summary, status,
			status_category, assignee_account_id, assignee_display_name, created_at, updated_at
		FROM jira_issues WHERE is_deleted = 0
		UNION ALL
		SELECT l.account_id, l.key, 'linked', l.project_key, 0, l.summary, l.status,
			l.status_category, l.assignee_account_id, l.assignee_display_name, l.created_at, l.updated_at
		FROM jira_linked_issues l WHERE l.fetch_error = ''
		  AND NOT EXISTS (SELECT 1 FROM jira_issues b WHERE b.account_id = l.account_id AND b.key = l.key AND b.is_deleted = 0)
	) h
	LEFT JOIN jira_changelog_sync c ON c.account_id = h.account_id AND c.issue_key = h.key`

// ListJiraHistoryIssues returns the issues f selects, board issues first,
// each (account, key) once.
func (db *DB) ListJiraHistoryIssues(f JiraHistoryFilter) ([]JiraHistoryIssue, error) {
	var where []string
	var args []any
	if f.AccountID > 0 {
		where = append(where, "h.account_id = ?")
		args = append(args, f.AccountID)
	}
	if len(f.Keys) > 0 {
		keysJSON, _ := json.Marshal(f.Keys)
		where = append(where, "h.key IN (SELECT value FROM json_each(?))")
		args = append(args, string(keysJSON))
	} else {
		where = append(where, "h.source = 'board'")
	}
	if f.BoardID > 0 {
		where = append(where, "h.board_id = ?")
		args = append(args, f.BoardID)
	}
	if f.ProjectKey != "" {
		where = append(where, "h.project_key = ?")
		args = append(args, f.ProjectKey)
	}
	if f.ActiveSince != "" {
		where = append(where, "(h.status_category != 'done' OR h.updated_at >= ?)")
		args = append(args, f.ActiveSince)
	}
	base, err := db.queryHistoryIssues(historyIssueSelect+" WHERE "+strings.Join(where, " AND ")+
		" ORDER BY h.source, h.account_id, h.key", args...)
	if err != nil {
		return nil, err
	}
	if !f.IncludeLinked || len(base) == 0 {
		return base, nil
	}

	linked, err := db.linkedHistoryIssues(base, f.ActiveSince)
	if err != nil {
		return nil, err
	}
	seen := make(map[string]bool, len(base))
	for _, is := range base {
		seen[historyIssueID(is.AccountID, is.Key)] = true
	}
	for _, is := range linked {
		if id := historyIssueID(is.AccountID, is.Key); !seen[id] {
			seen[id] = true
			base = append(base, is)
		}
	}
	return base, nil
}

func historyIssueID(accountID int64, key string) string {
	return fmt.Sprintf("%d/%s", accountID, key)
}

// linkedHistoryIssues returns the issues (board or linked) linked with the
// base issues, per account.
func (db *DB) linkedHistoryIssues(base []JiraHistoryIssue, activeSince string) ([]JiraHistoryIssue, error) {
	byAccount := map[int64][]string{}
	for _, is := range base {
		byAccount[is.AccountID] = append(byAccount[is.AccountID], is.Key)
	}
	var out []JiraHistoryIssue
	for accountID, keys := range byAccount {
		keysJSON, _ := json.Marshal(keys)
		// A link shared by two synced issues is stored once, under whichever
		// side was written last, so both directions are followed.
		q := historyIssueSelect + ` WHERE h.account_id = ? AND h.key IN (
			SELECT target_key FROM jira_issue_links
			WHERE account_id = ? AND source_key IN (SELECT value FROM json_each(?))
			UNION
			SELECT source_key FROM jira_issue_links
			WHERE account_id = ? AND target_key IN (SELECT value FROM json_each(?)))`
		args := []any{accountID, accountID, string(keysJSON), accountID, string(keysJSON)}
		if activeSince != "" {
			q += " AND (h.status_category != 'done' OR h.updated_at >= ?)"
			args = append(args, activeSince)
		}
		rows, err := db.queryHistoryIssues(q+" ORDER BY h.source, h.key", args...)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	return out, nil
}

func (db *DB) queryHistoryIssues(q string, args ...any) ([]JiraHistoryIssue, error) {
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing jira history issues: %w", err)
	}
	defer rows.Close()
	var out []JiraHistoryIssue
	for rows.Next() {
		var is JiraHistoryIssue
		if err := rows.Scan(&is.AccountID, &is.Key, &is.Source, &is.ProjectKey, &is.BoardID, &is.Summary,
			&is.Status, &is.StatusCategory, &is.AssigneeAccountID, &is.AssigneeDisplayName,
			&is.CreatedAt, &is.UpdatedAt, &is.ChangelogUpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning jira history issue: %w", err)
		}
		out = append(out, is)
	}
	return out, rows.Err()
}

// ListJiraIssueChangelog returns the stored changelog of the given issues of
// one account, keyed by issue key, each oldest first.
func (db *DB) ListJiraIssueChangelog(accountID int64, keys []string) (map[string][]JiraChangelogItem, error) {
	out := map[string][]JiraChangelogItem{}
	if len(keys) == 0 {
		return out, nil
	}
	keysJSON, _ := json.Marshal(keys)
	rows, err := db.Query(`SELECT issue_key, history_id, field, from_value, from_string, to_value, to_string,
			author_account_id, author_display_name, changed_at
		FROM jira_issue_changelog
		WHERE account_id = ? AND issue_key IN (SELECT value FROM json_each(?))
		ORDER BY issue_key, changed_at, CAST(history_id AS INTEGER), history_id, field`, accountID, string(keysJSON))
	if err != nil {
		return nil, fmt.Errorf("listing jira changelog: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		it := JiraChangelogItem{AccountID: accountID}
		if err := rows.Scan(&it.IssueKey, &it.HistoryID, &it.Field, &it.FromValue, &it.FromString, &it.ToValue,
			&it.ToString, &it.AuthorAccountID, &it.AuthorDisplayName, &it.ChangedAt); err != nil {
			return nil, fmt.Errorf("scanning jira changelog: %w", err)
		}
		out[it.IssueKey] = append(out[it.IssueKey], it)
	}
	return out, rows.Err()
}

// JiraStatusCategories maps every status name seen on a synced or linked
// issue to its normalized category ("todo"/"in_progress"/"done"). The
// changelog stores status names only, so this is how a historical status is
// told apart; a name seen with two categories (two workflows) takes the one
// most issues show.
func (db *DB) JiraStatusCategories() (map[string]string, error) {
	rows, err := db.Query(`SELECT status, status_category, COUNT(*) AS n FROM (
			SELECT status, status_category FROM jira_issues WHERE status != '' AND is_deleted = 0
			UNION ALL SELECT status, status_category FROM jira_linked_issues WHERE status != ''
		) GROUP BY status, status_category ORDER BY status, n DESC, status_category`)
	if err != nil {
		return nil, fmt.Errorf("listing jira status categories: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, cat string
		var n int
		if err := rows.Scan(&name, &cat, &n); err != nil {
			return nil, fmt.Errorf("scanning jira status category: %w", err)
		}
		if _, ok := out[name]; !ok {
			out[name] = cat
		}
	}
	return out, rows.Err()
}
