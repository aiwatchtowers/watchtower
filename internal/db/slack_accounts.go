package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// SlackAccount is one row of slack_accounts — a connected Slack workspace.
// Replaces the workspace singleton's current_user_id/search_last_date
// scalars, which used to live as workspace columns (see migration 00048).
type SlackAccount struct {
	ID             int64
	TeamID         string
	TeamName       string
	TeamDomain     string
	Label          string
	CurrentUserID  string // namespaced, e.g. "2:U0123"
	Status         string // ok | error | revoked | removed
	Error          string
	Enabled        bool
	SearchLastDate string
	CreatedAt      string
}

// FormatConnectedWorkspaces renders "<label1> (<domain1>), <label2> (<domain2>)"
// for AI system-prompt / status-line display. An account's label is preferred,
// falling back to its team name; a missing domain drops the parenthetical.
// Empty slice -> "".
func FormatConnectedWorkspaces(accounts []SlackAccount) string {
	parts := make([]string, 0, len(accounts))
	for _, a := range accounts {
		name := a.Label
		if name == "" {
			name = a.TeamName
		}
		if a.TeamDomain != "" {
			parts = append(parts, fmt.Sprintf("%s (%s)", name, a.TeamDomain))
		} else {
			parts = append(parts, name)
		}
	}
	return strings.Join(parts, ", ")
}

// slackAccountColumns is the shared column list for ListSlackAccounts,
// ListEnabledSlackAccounts, and GetSlackAccount — one place to keep the
// SELECT list and scanSlackAccount's Scan targets in lockstep.
const slackAccountColumns = `id, team_id, team_name, team_domain, label, current_user_id,
        status, error, enabled, search_last_date, created_at`

// scanSlackAccount scans one slackAccountColumns row from either *sql.Row or
// *sql.Rows (the jira.scanJiraIssue precedent).
func scanSlackAccount(scanner interface{ Scan(dest ...any) error }) (SlackAccount, error) {
	var a SlackAccount
	err := scanner.Scan(&a.ID, &a.TeamID, &a.TeamName, &a.TeamDomain, &a.Label, &a.CurrentUserID,
		&a.Status, &a.Error, &a.Enabled, &a.SearchLastDate, &a.CreatedAt)
	return a, err
}

// CreateSlackAccount inserts a new connected Slack account and returns its ID.
func (db *DB) CreateSlackAccount(a SlackAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO slack_accounts
        (team_id, team_name, team_domain, label, current_user_id)
        VALUES (?,?,?,?,?)`,
		a.TeamID, a.TeamName, a.TeamDomain, a.Label, a.CurrentUserID)
	if err != nil {
		return 0, fmt.Errorf("creating slack account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new slack account id: %w", err)
	}
	return id, nil
}

// ListSlackAccounts returns every connected Slack account, oldest first.
func (db *DB) ListSlackAccounts() ([]SlackAccount, error) {
	rows, err := db.Query(`SELECT ` + slackAccountColumns + ` FROM slack_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing slack accounts: %w", err)
	}
	defer rows.Close()
	var out []SlackAccount
	for rows.Next() {
		a, err := scanSlackAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning slack account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListEnabledSlackAccounts returns every enabled, non-removed connected
// Slack account, oldest first.
func (db *DB) ListEnabledSlackAccounts() ([]SlackAccount, error) {
	rows, err := db.Query(`SELECT ` + slackAccountColumns + ` FROM slack_accounts WHERE enabled = 1 AND status != 'removed' ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing enabled slack accounts: %w", err)
	}
	defer rows.Close()
	var out []SlackAccount
	for rows.Next() {
		a, err := scanSlackAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning slack account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetSlackAccount returns a single connected Slack account by ID.
func (db *DB) GetSlackAccount(id int64) (SlackAccount, error) {
	a, err := scanSlackAccount(db.QueryRow(`SELECT `+slackAccountColumns+` FROM slack_accounts WHERE id = ?`, id))
	if err != nil {
		return SlackAccount{}, fmt.Errorf("getting slack account %d: %w", id, err)
	}
	return a, nil
}

// UpdateSlackAccountConnection updates the resolved team info and current
// user id for accountID — called once auth.test/team.info resolve.
func (db *DB) UpdateSlackAccountConnection(id int64, teamID, teamName, teamDomain, currentUserID string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET team_id = ?, team_name = ?, team_domain = ?,
        current_user_id = ? WHERE id = ?`,
		teamID, teamName, teamDomain, currentUserID, id)
	if err != nil {
		return fmt.Errorf("updating slack account %d connection: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("updating slack account connection: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountEnabled toggles whether accountID is synced.
func (db *DB) SetSlackAccountEnabled(id int64, enabled bool) error {
	res, err := db.Exec(`UPDATE slack_accounts SET enabled = ? WHERE id = ?`, enabled, id)
	if err != nil {
		return fmt.Errorf("setting enabled for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting enabled: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "error", "revoked", "removed".
func (db *DB) SetSlackAccountAuthState(id int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting auth state for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting auth state: no slack_accounts row %d", id)
	}
	return nil
}

// SetSlackAccountRemoved marks accountID as removed and disables it — a
// non-destructive soft delete, so the row (and any data it left behind)
// stays reachable by ID.
func (db *DB) SetSlackAccountRemoved(id int64) error {
	res, err := db.Exec(`UPDATE slack_accounts SET status = 'removed', enabled = 0 WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("removing slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("removing slack account: no slack_accounts row %d", id)
	}
	return nil
}

// GetSlackAccountSearchWatermark returns the search.messages sync watermark
// (empty if unset or the account is missing) for accountID — the
// per-account replacement for the old workspace.search_last_date scalar.
func (db *DB) GetSlackAccountSearchWatermark(id int64) (string, error) {
	var date string
	err := db.QueryRow(`SELECT search_last_date FROM slack_accounts WHERE id = ?`, id).Scan(&date)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("getting search watermark for slack account %d: %w", id, err)
	}
	return date, nil
}

// SetSlackAccountSearchWatermark advances the search.messages sync
// watermark for accountID.
func (db *DB) SetSlackAccountSearchWatermark(id int64, date string) error {
	res, err := db.Exec(`UPDATE slack_accounts SET search_last_date = ? WHERE id = ?`, date, id)
	if err != nil {
		return fmt.Errorf("setting search watermark for slack account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting search watermark: no slack_accounts row %d", id)
	}
	return nil
}

// ListOwnerSlackUserIDs returns the namespaced current_user_id of every
// connected Slack account that has resolved an identity — the owner's
// identity across all workspaces, for own-message suppression. Deliberately
// unscoped by enabled/status (unlike ListEnabledSlackAccounts): messages
// synced before an account was disabled or removed stay in the DB and stay
// queryable (the non-destructive `slack remove` contract), so excluding a
// disabled/removed account here would let the owner's own already-synced
// messages in that account re-enter stream-candidate triage (audit medium,
// mirrors how autoResolveSlack resolves items against ListSlackAccounts).
func (db *DB) ListOwnerSlackUserIDs() ([]string, error) {
	rows, err := db.Query(`SELECT current_user_id FROM slack_accounts
		WHERE current_user_id != ''`)
	if err != nil {
		return nil, fmt.Errorf("listing owner slack user ids: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning owner slack user id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
