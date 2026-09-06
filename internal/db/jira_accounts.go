package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// ErrJiraAccountNotFound is what GetJiraAccount wraps when no row matches, so
// a caller can tell "that account does not exist" from "the lookup failed"
// (the memory/skills ErrNotFound precedent). Relabelling every getter error as
// "no such account" is the one wrong answer: it reports a broken DB as a typo.
var ErrJiraAccountNotFound = errors.New("jira account not found")

// JiraAccount is one connected Atlassian site (jira_accounts, migration
// 00049). Site-scoped jira_* rows reference it via account_id.
type JiraAccount struct {
	ID                        int64
	CloudID                   string
	SiteURL                   string
	SiteName                  string
	Label                     string
	Status                    string
	Error                     string
	Enabled                   bool
	MemoryJiraLastExtractedTS float64
	CreatedAt                 string
}

// CreateJiraAccount inserts a new connected Jira account and returns its ID.
func (db *DB) CreateJiraAccount(a JiraAccount) (int64, error) {
	res, err := db.Exec(`INSERT INTO jira_accounts
        (cloud_id, site_url, site_name, label)
        VALUES (?,?,?,?)`,
		a.CloudID, a.SiteURL, a.SiteName, a.Label)
	if err != nil {
		return 0, fmt.Errorf("creating jira account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new jira account id: %w", err)
	}
	return id, nil
}

// ListJiraAccounts returns every connected Jira account, oldest first.
func (db *DB) ListJiraAccounts() ([]JiraAccount, error) {
	rows, err := db.Query(`SELECT id, cloud_id, site_url, site_name, label,
        status, error, enabled, memory_jira_last_extracted_ts, created_at
        FROM jira_accounts ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing jira accounts: %w", err)
	}
	defer rows.Close()
	var out []JiraAccount
	for rows.Next() {
		var a JiraAccount
		if err := rows.Scan(&a.ID, &a.CloudID, &a.SiteURL, &a.SiteName, &a.Label,
			&a.Status, &a.Error, &a.Enabled, &a.MemoryJiraLastExtractedTS, &a.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning jira account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListEnabledJiraAccounts returns every enabled, non-removed connected Jira
// account, oldest first.
func (db *DB) ListEnabledJiraAccounts() ([]JiraAccount, error) {
	rows, err := db.Query(`SELECT id, cloud_id, site_url, site_name, label,
        status, error, enabled, memory_jira_last_extracted_ts, created_at
        FROM jira_accounts WHERE enabled = 1 AND status != 'removed' ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing enabled jira accounts: %w", err)
	}
	defer rows.Close()
	var out []JiraAccount
	for rows.Next() {
		var a JiraAccount
		if err := rows.Scan(&a.ID, &a.CloudID, &a.SiteURL, &a.SiteName, &a.Label,
			&a.Status, &a.Error, &a.Enabled, &a.MemoryJiraLastExtractedTS, &a.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning jira account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetJiraAccount returns a single connected Jira account by ID.
func (db *DB) GetJiraAccount(id int64) (JiraAccount, error) {
	var a JiraAccount
	err := db.QueryRow(`SELECT id, cloud_id, site_url, site_name, label,
        status, error, enabled, memory_jira_last_extracted_ts, created_at
        FROM jira_accounts WHERE id = ?`, id).
		Scan(&a.ID, &a.CloudID, &a.SiteURL, &a.SiteName, &a.Label,
			&a.Status, &a.Error, &a.Enabled, &a.MemoryJiraLastExtractedTS, &a.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		// A mistyped --account must not surface the stdlib sentinel — but it
		// must not lose the distinction either, hence ErrJiraAccountNotFound.
		return JiraAccount{}, fmt.Errorf("%w: #%d (see 'watchtower jira accounts')", ErrJiraAccountNotFound, id)
	}
	if err != nil {
		return JiraAccount{}, fmt.Errorf("getting jira account %d: %w", id, err)
	}
	return a, nil
}

// UpdateJiraAccountConnection updates the resolved site identity for
// accountID — called once the OAuth flow resolves accessible resources.
func (db *DB) UpdateJiraAccountConnection(id int64, cloudID, siteURL, siteName string) error {
	res, err := db.Exec(`UPDATE jira_accounts SET cloud_id = ?, site_url = ?, site_name = ? WHERE id = ?`,
		cloudID, siteURL, siteName, id)
	if err != nil {
		return fmt.Errorf("updating jira account %d connection: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("updating jira account connection: no jira_accounts row %d", id)
	}
	return nil
}

// SetJiraAccountEnabled toggles whether accountID is synced.
func (db *DB) SetJiraAccountEnabled(id int64, enabled bool) error {
	res, err := db.Exec(`UPDATE jira_accounts SET enabled = ? WHERE id = ?`, enabled, id)
	if err != nil {
		return fmt.Errorf("setting enabled for jira account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting enabled: no jira_accounts row %d", id)
	}
	return nil
}

// SetJiraAccountAuthState updates status/error telemetry for accountID.
// status is one of "ok", "error", "revoked", "removed".
func (db *DB) SetJiraAccountAuthState(id int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE jira_accounts SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting auth state for jira account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting auth state: no jira_accounts row %d", id)
	}
	return nil
}

// SetJiraAccountRemoved marks accountID as removed and disables it — a
// non-destructive soft delete (the Slack precedent, not Google's cascade):
// synced data stays queryable and the row keeps site_url attribution for
// historical issue links.
func (db *DB) SetJiraAccountRemoved(id int64) error {
	res, err := db.Exec(`UPDATE jira_accounts SET status = 'removed', enabled = 0 WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("removing jira account %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("removing jira account: no jira_accounts row %d", id)
	}
	return nil
}
