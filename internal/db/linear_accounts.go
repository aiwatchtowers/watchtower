package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrLinearAccountNotFound is what GetLinearAccount wraps when no row matches
// (the ErrJiraAccountNotFound precedent).
var ErrLinearAccountNotFound = errors.New("linear account not found")

// LinearAccount is one connected Linear workspace (linear_accounts, migration
// 00116). Every other linear_* row references it via account_id.
type LinearAccount struct {
	ID               int64
	OrgID            string
	URLKey           string
	OrgName          string
	Label            string
	Status           string
	Error            string
	Enabled          bool
	OwnerUserID      string
	OwnerEmail       string
	OwnerDisplayName string
	CreatedAt        string
}

const linearAccountColumns = `id, org_id, url_key, org_name, label, status, error, enabled,
        owner_user_id, owner_email, owner_display_name, created_at`

func scanLinearAccount(s interface{ Scan(dest ...any) error }) (LinearAccount, error) {
	var a LinearAccount
	err := s.Scan(&a.ID, &a.OrgID, &a.URLKey, &a.OrgName, &a.Label, &a.Status, &a.Error, &a.Enabled,
		&a.OwnerUserID, &a.OwnerEmail, &a.OwnerDisplayName, &a.CreatedAt)
	return a, err
}

// CreateLinearAccount inserts a new, not yet resolved Linear account.
func (db *DB) CreateLinearAccount(label string) (int64, error) {
	res, err := db.Exec(`INSERT INTO linear_accounts (label) VALUES (?)`, strings.TrimSpace(label))
	if err != nil {
		return 0, fmt.Errorf("creating linear account: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new linear account id: %w", err)
	}
	return id, nil
}

func (db *DB) queryLinearAccounts(what, where string) ([]LinearAccount, error) {
	rows, err := db.Query(`SELECT ` + linearAccountColumns + ` FROM linear_accounts` + where + ` ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing %slinear accounts: %w", what, err)
	}
	defer rows.Close()
	var out []LinearAccount
	for rows.Next() {
		a, err := scanLinearAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning linear account: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListLinearAccounts returns every Linear account, oldest first.
func (db *DB) ListLinearAccounts() ([]LinearAccount, error) {
	return db.queryLinearAccounts("", "")
}

// ListEnabledLinearAccounts returns every enabled, non-removed account.
func (db *DB) ListEnabledLinearAccounts() ([]LinearAccount, error) {
	return db.queryLinearAccounts("enabled ", ` WHERE enabled = 1 AND status != 'removed'`)
}

// GetLinearAccount returns one account by id, wrapping ErrLinearAccountNotFound.
func (db *DB) GetLinearAccount(id int64) (LinearAccount, error) {
	a, err := scanLinearAccount(db.QueryRow(`SELECT `+linearAccountColumns+` FROM linear_accounts WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return LinearAccount{}, fmt.Errorf("%w: #%d (see 'watchtower linear accounts')", ErrLinearAccountNotFound, id)
	}
	if err != nil {
		return LinearAccount{}, fmt.Errorf("getting linear account %d: %w", id, err)
	}
	return a, nil
}

func (db *DB) execLinearAccount(action, query string, args ...any) error {
	res, err := db.Exec(query, args...)
	if err != nil {
		return fmt.Errorf("%s: %w", action, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("%s: no linear_accounts row", action)
	}
	return nil
}

// UpdateLinearAccountConnection records the resolved workspace identity and
// gives a still-unlabeled account its automatic label (the org name).
func (db *DB) UpdateLinearAccountConnection(id int64, orgID, urlKey, orgName string) error {
	if err := db.execLinearAccount(fmt.Sprintf("updating linear account %d connection", id),
		`UPDATE linear_accounts SET org_id = ?, url_key = ?, org_name = ? WHERE id = ?`,
		orgID, urlKey, orgName, id); err != nil {
		return err
	}
	db.fillAccountLabelBestEffort("linear_accounts", id, orgName)
	return nil
}

// SetLinearAccountOwner records the connecting person's own Linear identity.
func (db *DB) SetLinearAccountOwner(id int64, userID, email, displayName string) error {
	return db.execLinearAccount(fmt.Sprintf("setting linear account %d owner", id),
		`UPDATE linear_accounts SET owner_user_id = ?, owner_email = ?, owner_display_name = ? WHERE id = ?`,
		userID, email, displayName, id)
}

// SetLinearAccountEnabled toggles whether the account is synced.
func (db *DB) SetLinearAccountEnabled(id int64, enabled bool) error {
	return db.execLinearAccount(fmt.Sprintf("setting linear account %d enabled", id),
		`UPDATE linear_accounts SET enabled = ? WHERE id = ?`, enabled, id)
}

// SetLinearAccountAuthState records status (ok | error | revoked) and its error text.
func (db *DB) SetLinearAccountAuthState(id int64, status, errMsg string) error {
	return db.execLinearAccount(fmt.Sprintf("setting linear account %d auth state", id),
		`UPDATE linear_accounts SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
}

// SetLinearAccountRemoved soft-deletes the account: the row and its data stay.
func (db *DB) SetLinearAccountRemoved(id int64) error {
	return db.execLinearAccount(fmt.Sprintf("removing linear account %d", id),
		`UPDATE linear_accounts SET status = 'removed', enabled = 0 WHERE id = ?`, id)
}

// SetLinearAccountLabel renames the account.
func (db *DB) SetLinearAccountLabel(id int64, label string) error {
	return db.execLinearAccount(fmt.Sprintf("setting linear account %d label", id),
		`UPDATE linear_accounts SET label = ? WHERE id = ?`, strings.TrimSpace(label), id)
}
