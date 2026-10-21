package db

import (
	"fmt"
)

// AccountPurge is one row of the account_purges ledger (migration 00147,
// board #601).
type AccountPurge struct {
	ID          int64
	Source      string // slack | google | jira | linear
	AccountID   int64
	Reason      string // revoked | lease
	ScheduledAt string
	DueAt       string // RFC 3339 UTC
	State       string // scheduled | running | done | cancelled
	StartedAt   string
	FinishedAt  string
	RowsDeleted int64
	Error       string
}

// PurgeAccount is one account as the purge scheduler sees it.
type PurgeAccount struct {
	Source     string
	ID         int64
	Label      string
	Status     string
	Enabled    bool
	AccessOKAt string
	RevokedAt  string
}

// listPurgeAccountsSQL reads every account of the four sources, every status
// (removed accounts take part in the lease, ask #477). The label falls back
// to the source's own name for the account.
const listPurgeAccountsSQL = `
SELECT 'slack', id, COALESCE(NULLIF(label, ''), NULLIF(team_name, ''), team_domain), status, enabled, access_ok_at, revoked_at FROM slack_accounts
UNION ALL
SELECT 'google', id, COALESCE(NULLIF(label, ''), email), status, (gmail_enabled OR calendar_enabled), access_ok_at, revoked_at FROM google_accounts
UNION ALL
SELECT 'jira', id, COALESCE(NULLIF(label, ''), NULLIF(site_name, ''), site_url), status, enabled, access_ok_at, revoked_at FROM jira_accounts
UNION ALL
SELECT 'linear', id, COALESCE(NULLIF(label, ''), NULLIF(org_name, ''), url_key), status, enabled, access_ok_at, revoked_at FROM linear_accounts
ORDER BY 1, 2`

// ListPurgeAccounts returns every Slack, Google, Jira and Linear account with
// its access facts.
func (db *DB) ListPurgeAccounts() ([]PurgeAccount, error) {
	rows, err := db.Query(listPurgeAccountsSQL)
	if err != nil {
		return nil, fmt.Errorf("listing purge accounts: %w", err)
	}
	defer rows.Close()
	var out []PurgeAccount
	for rows.Next() {
		var a PurgeAccount
		if err := rows.Scan(&a.Source, &a.ID, &a.Label, &a.Status, &a.Enabled, &a.AccessOKAt, &a.RevokedAt); err != nil {
			return nil, fmt.Errorf("scanning purge account: %w", err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing purge accounts: %w", err)
	}
	return out, nil
}

// ScheduleAccountPurge inserts a scheduled row unless the account already has
// an open (scheduled or running) one; it reports whether a row was inserted.
func (db *DB) ScheduleAccountPurge(source string, accountID int64, reason, dueAt string) (bool, error) {
	res, err := db.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at)
		VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`, source, accountID, reason, dueAt)
	if err != nil {
		return false, fmt.Errorf("scheduling %s account %d purge: %w", source, accountID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("scheduling %s account %d purge: %w", source, accountID, err)
	}
	return n > 0, nil
}

// CancelAccountPurge cancels one scheduled row; a running, done or cancelled
// row is left alone. It reports whether the row was cancelled.
func (db *DB) CancelAccountPurge(id int64) (bool, error) {
	res, err := db.Exec(`UPDATE account_purges SET state = 'cancelled',
		finished_at = `+nowSQL+` WHERE id = ? AND state = 'scheduled'`, id)
	if err != nil {
		return false, fmt.Errorf("cancelling account purge %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("cancelling account purge %d: %w", id, err)
	}
	return n > 0, nil
}

const accountPurgeColumns = `id, source, account_id, reason, scheduled_at, due_at, state,
	started_at, finished_at, rows_deleted, error`

// ListAccountPurges returns ledger rows newest first; openOnly keeps the
// scheduled and running ones.
func (db *DB) ListAccountPurges(openOnly bool) ([]AccountPurge, error) {
	q := `SELECT ` + accountPurgeColumns + ` FROM account_purges`
	if openOnly {
		q += ` WHERE state IN ('scheduled', 'running')`
	}
	q += ` ORDER BY id DESC`
	rows, err := db.Query(q)
	if err != nil {
		return nil, fmt.Errorf("listing account purges: %w", err)
	}
	defer rows.Close()
	var out []AccountPurge
	for rows.Next() {
		var p AccountPurge
		if err := rows.Scan(&p.ID, &p.Source, &p.AccountID, &p.Reason, &p.ScheduledAt, &p.DueAt, &p.State,
			&p.StartedAt, &p.FinishedAt, &p.RowsDeleted, &p.Error); err != nil {
			return nil, fmt.Errorf("scanning account purge: %w", err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing account purges: %w", err)
	}
	return out, nil
}

// AccountPurgeRunning reports whether the account has a running purge. The
// login paths refuse to write credentials then: the purge would delete them
// when it finishes.
func (db *DB) AccountPurgeRunning(source string, accountID int64) (bool, error) {
	var running bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM account_purges
		WHERE source = ? AND account_id = ? AND state = 'running')`, source, accountID).Scan(&running); err != nil {
		return false, fmt.Errorf("reading %s account %d purge: %w", source, accountID, err)
	}
	return running, nil
}
