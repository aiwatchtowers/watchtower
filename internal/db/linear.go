package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
)

// LinearTeam is one Linear team of an account; IsSelected is the owner's choice.
type LinearTeam struct {
	AccountID  int64
	ID         string
	Key        string
	Name       string
	IsSelected bool
}

// UpsertLinearTeams inserts new teams with is_selected = selectNew[team.ID]
// and refreshes key/name of known teams without touching their selection.
func (db *DB) UpsertLinearTeams(accountID int64, teams []LinearTeam, selectNew map[string]bool) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear teams: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	for _, t := range teams {
		if _, err := tx.Exec(`INSERT INTO linear_teams (account_id, id, key, name, is_selected) VALUES (?,?,?,?,?)
			ON CONFLICT(account_id, id) DO UPDATE SET key = excluded.key, name = excluded.name`,
			accountID, t.ID, t.Key, t.Name, selectNew[t.ID]); err != nil {
			return fmt.Errorf("upserting linear team %s: %w", t.Key, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("upserting linear teams: %w", err)
	}
	return nil
}

// ListLinearTeams returns the account's teams ordered by key.
func (db *DB) ListLinearTeams(accountID int64) ([]LinearTeam, error) {
	rows, err := db.Query(`SELECT account_id, id, key, name, is_selected FROM linear_teams
		WHERE account_id = ? ORDER BY key, id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("listing linear teams: %w", err)
	}
	defer rows.Close()
	var out []LinearTeam
	for rows.Next() {
		var t LinearTeam
		if err := rows.Scan(&t.AccountID, &t.ID, &t.Key, &t.Name, &t.IsSelected); err != nil {
			return nil, fmt.Errorf("scanning linear team: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SetLinearTeamSelected flips the selection of the team with teamKey.
func (db *DB) SetLinearTeamSelected(accountID int64, teamKey string, selected bool) error {
	res, err := db.Exec(`UPDATE linear_teams SET is_selected = ? WHERE account_id = ? AND key = ?`,
		selected, accountID, teamKey)
	if err != nil {
		return fmt.Errorf("selecting linear team %s: %w", teamKey, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("selecting linear team: no team %q on account %d", teamKey, accountID)
	}
	return nil
}

// LinearSyncState is the per-team incremental-sync cursor.
type LinearSyncState struct {
	AccountID    int64
	TeamID       string
	Watermark    string
	LastSyncedAt string
	LastError    string
}

// GetLinearSyncState returns the zero value (with the keys set) when missing.
func (db *DB) GetLinearSyncState(accountID int64, teamID string) (LinearSyncState, error) {
	s := LinearSyncState{AccountID: accountID, TeamID: teamID}
	err := db.QueryRow(`SELECT watermark, last_synced_at, last_error FROM linear_sync_state
		WHERE account_id = ? AND team_id = ?`, accountID, teamID).Scan(&s.Watermark, &s.LastSyncedAt, &s.LastError)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return LinearSyncState{}, fmt.Errorf("getting linear sync state: %w", err)
	}
	return s, nil
}

// RecordLinearSyncSuccess stores a finished pass: clears last_error; an empty
// watermark keeps the stored one.
func (db *DB) RecordLinearSyncSuccess(accountID int64, teamID, watermark, syncedAt string) error {
	_, err := db.Exec(`INSERT INTO linear_sync_state (account_id, team_id, watermark, last_synced_at, last_error)
		VALUES (?,?,?,?, '')
		ON CONFLICT(account_id, team_id) DO UPDATE SET
		  watermark = CASE WHEN excluded.watermark != '' THEN excluded.watermark ELSE linear_sync_state.watermark END,
		  last_synced_at = excluded.last_synced_at, last_error = ''`, accountID, teamID, watermark, syncedAt)
	if err != nil {
		return fmt.Errorf("recording linear sync success: %w", err)
	}
	return nil
}

// RecordLinearSyncError stores a failed pass; the watermark is untouched.
func (db *DB) RecordLinearSyncError(accountID int64, teamID, errMsg string) error {
	_, err := db.Exec(`INSERT INTO linear_sync_state (account_id, team_id, last_error) VALUES (?,?,?)
		ON CONFLICT(account_id, team_id) DO UPDATE SET last_error = excluded.last_error`, accountID, teamID, errMsg)
	if err != nil {
		return fmt.Errorf("recording linear sync error: %w", err)
	}
	return nil
}

// GetLinearMovedWatermark returns the account's moved-issue reconcile cursor
// ("" until the first reconcile).
func (db *DB) GetLinearMovedWatermark(accountID int64) (string, error) {
	var w string
	err := db.QueryRow(`SELECT moved_watermark FROM linear_accounts WHERE id = ?`, accountID).Scan(&w)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Errorf("getting linear moved watermark: %w", err)
	}
	return w, nil
}

// SetLinearMovedWatermark stores the moved-issue reconcile cursor.
func (db *DB) SetLinearMovedWatermark(accountID int64, watermark string) error {
	if _, err := db.Exec(`UPDATE linear_accounts SET moved_watermark = ? WHERE id = ?`, watermark, accountID); err != nil {
		return fmt.Errorf("setting linear moved watermark: %w", err)
	}
	return nil
}

// ListLinearSyncStates returns every sync state of the account, by team id.
func (db *DB) ListLinearSyncStates(accountID int64) ([]LinearSyncState, error) {
	rows, err := db.Query(`SELECT account_id, team_id, watermark, last_synced_at, last_error
		FROM linear_sync_state WHERE account_id = ? ORDER BY team_id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("listing linear sync states: %w", err)
	}
	defer rows.Close()
	var out []LinearSyncState
	for rows.Next() {
		var s LinearSyncState
		if err := rows.Scan(&s.AccountID, &s.TeamID, &s.Watermark, &s.LastSyncedAt, &s.LastError); err != nil {
			return nil, fmt.Errorf("scanning linear sync state: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// LinearIssue is one linear_issues row (the slack ids are not part of it:
// BackfillLinearSlackIDs owns them).
type LinearIssue struct {
	AccountID           int64
	ID                  string
	Key                 string
	PreviousKeys        []string
	TeamID              string
	TeamKey             string
	Title               string
	DescriptionText     string
	StateName           string
	StateType           string
	StatusCategory      string
	StateChangedAt      string
	AssigneeID          string
	AssigneeEmail       string
	AssigneeDisplayName string
	CreatorID           string
	CreatorEmail        string
	CreatorDisplayName  string
	Priority            int
	Estimate            *float64
	DueDate             string
	CycleID             string
	ProjectID           string
	ParentID            string
	Labels              []string
	URL                 string
	CreatedAt           string
	UpdatedAt           string
	CompletedAt         string
	CanceledAt          string
	RawJSON             string
	IsDeleted           bool
}

// UpsertLinearIssue never writes assignee_slack_id/creator_slack_id: those
// belong to BackfillLinearSlackIDs (the jira BackfillJiraSlackIDs split). A
// changed assignee/creator resets the stored id until the next backfill.
const linearIssueUpsert = `INSERT INTO linear_issues (account_id, id, key, previous_keys, team_id, team_key, title,
  description_text, state_name, state_type, status_category, state_changed_at, assignee_id, assignee_email,
  assignee_display_name, creator_id, creator_email, creator_display_name, priority, estimate, due_date,
  cycle_id, project_id, parent_id, labels, url, created_at, updated_at, completed_at, canceled_at, raw_json,
  synced_at, is_deleted)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'), ?)
ON CONFLICT(account_id, id) DO UPDATE SET key=excluded.key, previous_keys=excluded.previous_keys,
  team_id=excluded.team_id, team_key=excluded.team_key, title=excluded.title,
  description_text=excluded.description_text, state_name=excluded.state_name, state_type=excluded.state_type,
  status_category=excluded.status_category, state_changed_at=excluded.state_changed_at,
  assignee_id=excluded.assignee_id, assignee_email=excluded.assignee_email,
  assignee_display_name=excluded.assignee_display_name,
  assignee_slack_id=CASE WHEN excluded.assignee_id = linear_issues.assignee_id THEN linear_issues.assignee_slack_id ELSE '' END,
  creator_id=excluded.creator_id, creator_email=excluded.creator_email,
  creator_display_name=excluded.creator_display_name,
  creator_slack_id=CASE WHEN excluded.creator_id = linear_issues.creator_id THEN linear_issues.creator_slack_id ELSE '' END,
  priority=excluded.priority, estimate=excluded.estimate,
  due_date=excluded.due_date, cycle_id=excluded.cycle_id, project_id=excluded.project_id,
  parent_id=excluded.parent_id, labels=excluded.labels, url=excluded.url, created_at=excluded.created_at,
  updated_at=excluded.updated_at, completed_at=excluded.completed_at, canceled_at=excluded.canceled_at,
  raw_json=excluded.raw_json, synced_at=excluded.synced_at, is_deleted=excluded.is_deleted`

// jsonList marshals a string slice; nil becomes "[]".
func jsonList(v []string) (string, error) {
	if v == nil {
		return "[]", nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func parseJSONList(s string) []string {
	var out []string
	if s == "" || json.Unmarshal([]byte(s), &out) != nil {
		return nil
	}
	return out
}

// UpsertLinearIssue inserts or refreshes one issue; synced_at is now.
func (db *DB) UpsertLinearIssue(i LinearIssue) error {
	prev, err := jsonList(i.PreviousKeys)
	if err != nil {
		return fmt.Errorf("encoding previous keys of %s: %w", i.Key, err)
	}
	labels, err := jsonList(i.Labels)
	if err != nil {
		return fmt.Errorf("encoding labels of %s: %w", i.Key, err)
	}
	raw := i.RawJSON
	if raw == "" {
		raw = "{}"
	}
	if _, err := db.Exec(linearIssueUpsert, i.AccountID, i.ID, i.Key, prev, i.TeamID, i.TeamKey, i.Title,
		i.DescriptionText, i.StateName, i.StateType, i.StatusCategory, i.StateChangedAt, i.AssigneeID, i.AssigneeEmail,
		i.AssigneeDisplayName, i.CreatorID, i.CreatorEmail, i.CreatorDisplayName, i.Priority, i.Estimate, i.DueDate,
		i.CycleID, i.ProjectID, i.ParentID, labels, i.URL, i.CreatedAt, i.UpdatedAt, i.CompletedAt, i.CanceledAt, raw,
		i.IsDeleted); err != nil {
		return fmt.Errorf("upserting linear issue %s: %w", i.Key, err)
	}
	return nil
}

// KnownLinearIssueIDs returns the ids among ids that the account already
// stores, in the order given.
func (db *DB) KnownLinearIssueIDs(accountID int64, ids []string) ([]string, error) {
	var out []string
	for _, id := range ids {
		var one int
		err := db.QueryRow(`SELECT 1 FROM linear_issues WHERE account_id = ? AND id = ?`, accountID, id).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("looking up linear issue %s: %w", id, err)
		}
		out = append(out, id)
	}
	return out, nil
}

// linearIssueColumns is the SELECT list scanLinearIssues reads, in order.
const linearIssueColumns = `account_id, id, key, previous_keys, team_id, team_key, title,
		description_text, state_name, state_type, status_category, state_changed_at, assignee_id, assignee_email,
		assignee_display_name, creator_id, creator_email, creator_display_name, priority, estimate, due_date,
		cycle_id, project_id, parent_id, labels, url, created_at, updated_at, completed_at, canceled_at, raw_json,
		is_deleted`

// scanLinearIssues reads every row of a linearIssueColumns query and closes
// rows.
func scanLinearIssues(rows *sql.Rows) ([]LinearIssue, error) {
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

// GetLinearIssueByKey matches the current key or a previous one, across accounts.
func (db *DB) GetLinearIssueByKey(key string) ([]LinearIssue, error) {
	rows, err := db.Query(`SELECT `+linearIssueColumns+`
		FROM linear_issues
		WHERE key = ? OR EXISTS (SELECT 1 FROM json_each(linear_issues.previous_keys) WHERE value = ?)
		ORDER BY account_id, id`, key, key)
	if err != nil {
		return nil, fmt.Errorf("getting linear issue %s: %w", key, err)
	}
	return scanLinearIssues(rows)
}

// LinearComment is one issue comment.
type LinearComment struct {
	AccountID         int64
	ID                string
	IssueID           string
	IssueKey          string
	AuthorID          string
	AuthorDisplayName string
	BodyText          string
	MentionedUserIDs  []string
	CreatedAt         string
	UpdatedAt         string
}

// UpsertLinearComment inserts or refreshes one comment.
func (db *DB) UpsertLinearComment(c LinearComment) error {
	mentioned, err := jsonList(c.MentionedUserIDs)
	if err != nil {
		return fmt.Errorf("encoding mentions of comment %s: %w", c.ID, err)
	}
	if _, err := db.Exec(`INSERT INTO linear_comments (account_id, id, issue_id, issue_key, author_id,
		author_display_name, body_text, mentioned_user_ids, created_at, updated_at, synced_at)
		VALUES (?,?,?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT(account_id, id) DO UPDATE SET issue_id=excluded.issue_id, issue_key=excluded.issue_key,
		  author_id=excluded.author_id, author_display_name=excluded.author_display_name,
		  body_text=excluded.body_text, mentioned_user_ids=excluded.mentioned_user_ids,
		  created_at=excluded.created_at, updated_at=excluded.updated_at, synced_at=excluded.synced_at`,
		c.AccountID, c.ID, c.IssueID, c.IssueKey, c.AuthorID, c.AuthorDisplayName, c.BodyText, mentioned,
		c.CreatedAt, c.UpdatedAt); err != nil {
		return fmt.Errorf("upserting linear comment %s: %w", c.ID, err)
	}
	return nil
}

// LinearHistoryEntry is one status or assignee change of an issue.
type LinearHistoryEntry struct {
	AccountID        int64
	ID               string
	Field            string
	IssueID          string
	FromValue        string
	FromString       string
	ToValue          string
	ToString         string
	ActorID          string
	ActorDisplayName string
	ChangedAt        string
}

// UpsertLinearHistory writes the entries in one transaction.
func (db *DB) UpsertLinearHistory(entries []LinearHistoryEntry) error {
	if len(entries) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear history: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	for _, e := range entries {
		if _, err := tx.Exec(`INSERT INTO linear_issue_history (account_id, id, field, issue_id, from_value,
			from_string, to_value, to_string, actor_id, actor_display_name, changed_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?)
			ON CONFLICT(account_id, id, field) DO UPDATE SET issue_id=excluded.issue_id,
			  from_value=excluded.from_value, from_string=excluded.from_string, to_value=excluded.to_value,
			  to_string=excluded.to_string, actor_id=excluded.actor_id,
			  actor_display_name=excluded.actor_display_name, changed_at=excluded.changed_at`,
			e.AccountID, e.ID, e.Field, e.IssueID, e.FromValue, e.FromString, e.ToValue, e.ToString,
			e.ActorID, e.ActorDisplayName, e.ChangedAt); err != nil {
			return fmt.Errorf("upserting linear history %s/%s: %w", e.ID, e.Field, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("upserting linear history: %w", err)
	}
	return nil
}

// LinearRelation is "issue_id <Type> RelatedIssueID" (A blocks B).
type LinearRelation struct {
	ID             string
	RelatedIssueID string
	Type           string
}

// ReplaceLinearRelations replaces every relation whose issue_id = issueID.
func (db *DB) ReplaceLinearRelations(accountID int64, issueID string, rels []LinearRelation) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("replacing linear relations: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	if _, err := tx.Exec(`DELETE FROM linear_relations WHERE account_id = ? AND issue_id = ?`, accountID, issueID); err != nil {
		return fmt.Errorf("clearing linear relations of %s: %w", issueID, err)
	}
	for _, r := range rels {
		// OR REPLACE: the same relation id may previously have belonged to another issue.
		if _, err := tx.Exec(`INSERT OR REPLACE INTO linear_relations (account_id, id, issue_id, related_issue_id, type)
			VALUES (?,?,?,?,?)`, accountID, r.ID, issueID, r.RelatedIssueID, r.Type); err != nil {
			return fmt.Errorf("inserting linear relation %s: %w", r.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("replacing linear relations: %w", err)
	}
	return nil
}

// LinearCycle is one team cycle (sprint).
type LinearCycle struct {
	AccountID   int64
	ID          string
	TeamID      string
	Number      int
	Name        string
	StartsAt    string
	EndsAt      string
	CompletedAt string
	Progress    float64
}

// UpsertLinearCycles writes the cycles in one transaction.
func (db *DB) UpsertLinearCycles(cycles []LinearCycle) error {
	if len(cycles) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear cycles: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	for _, c := range cycles {
		if _, err := tx.Exec(`INSERT INTO linear_cycles (account_id, id, team_id, number, name, starts_at,
			ends_at, completed_at, progress, synced_at)
			VALUES (?,?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			ON CONFLICT(account_id, id) DO UPDATE SET team_id=excluded.team_id, number=excluded.number,
			  name=excluded.name, starts_at=excluded.starts_at, ends_at=excluded.ends_at,
			  completed_at=excluded.completed_at, progress=excluded.progress, synced_at=excluded.synced_at`,
			c.AccountID, c.ID, c.TeamID, c.Number, c.Name, c.StartsAt, c.EndsAt, c.CompletedAt, c.Progress); err != nil {
			return fmt.Errorf("upserting linear cycle %s: %w", c.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("upserting linear cycles: %w", err)
	}
	return nil
}

// LinearProject is one Linear project.
type LinearProject struct {
	AccountID  int64
	ID         string
	Name       string
	State      string
	Progress   float64
	TargetDate string
	LeadID     string
	URL        string
}

// UpsertLinearProjects writes the projects in one transaction.
func (db *DB) UpsertLinearProjects(projects []LinearProject) error {
	if len(projects) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear projects: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	for _, p := range projects {
		if _, err := tx.Exec(`INSERT INTO linear_projects (account_id, id, name, state, progress, target_date,
			lead_id, url, synced_at)
			VALUES (?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			ON CONFLICT(account_id, id) DO UPDATE SET name=excluded.name, state=excluded.state,
			  progress=excluded.progress, target_date=excluded.target_date, lead_id=excluded.lead_id,
			  url=excluded.url, synced_at=excluded.synced_at`,
			p.AccountID, p.ID, p.Name, p.State, p.Progress, p.TargetDate, p.LeadID, p.URL); err != nil {
			return fmt.Errorf("upserting linear project %s: %w", p.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("upserting linear projects: %w", err)
	}
	return nil
}

// LinearUser is a Linear user as the sync sees it.
type LinearUser struct {
	ID          string
	Email       string
	DisplayName string
}

// UpsertLinearUsers refreshes email/display_name and never touches
// slack_user_id/match_*.
func (db *DB) UpsertLinearUsers(users []LinearUser) error {
	if len(users) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear users: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	for _, u := range users {
		if _, err := tx.Exec(`INSERT INTO linear_user_map (linear_user_id, email, display_name) VALUES (?,?,?)
			ON CONFLICT(linear_user_id) DO UPDATE SET email = excluded.email, display_name = excluded.display_name`,
			u.ID, u.Email, u.DisplayName); err != nil {
			return fmt.Errorf("upserting linear user %s: %w", u.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("upserting linear users: %w", err)
	}
	return nil
}

// BackfillLinearSlackIDs copies linear_user_map.slack_user_id onto
// linear_issues.assignee_slack_id/creator_slack_id for one account; returns
// the rows changed.
func (db *DB) BackfillLinearSlackIDs(accountID int64) (int64, error) {
	res, err := db.Exec(`UPDATE linear_issues SET
  assignee_slack_id = COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.assignee_id), ''),
  creator_slack_id  = COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.creator_id), '')
WHERE account_id = ? AND (
  assignee_slack_id != COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.assignee_id), '') OR
  creator_slack_id  != COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.creator_id), ''))`, accountID)
	if err != nil {
		return 0, fmt.Errorf("backfilling linear slack ids: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("backfilling linear slack ids: %w", err)
	}
	return n, nil
}
