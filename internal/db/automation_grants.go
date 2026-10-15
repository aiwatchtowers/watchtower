package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// AutomationToolGrant is the owner's auto grant for one (automation, tool)
// (automation_tool_grants, migration 00115; spec §6.4).
type AutomationToolGrant struct {
	AutomationID int64
	Tool         string
	GrantHash    string
	GrantedAt    time.Time
	// Active is grant_hash = automations.approval_hash (non-empty): the recipe
	// has not changed since the grant. A run's own recipe_hash is checked
	// per call by ActiveAutomationToolGrant.
	Active bool
}

// SetAutomationToolGrant records the owner's auto grant of tool to automation
// automationID for hash. In one transaction it refuses with ErrHashMismatch
// unless hash is the row's current, non-empty approval_hash, and with
// ErrAutomationNotFound when there is no row; a re-grant overwrites the hash and
// granted_at. Callers (the `automations auto … on` command) enforce the
// AGENT-07, AlwaysAsk and manifest refusals; this store enforces only the hash.
func (db *DB) SetAutomationToolGrant(automationID int64, tool, hash string, now time.Time) error {
	if hash == "" {
		return fmt.Errorf("granting %s to automation %d: empty hash: %w", tool, automationID, ErrHashMismatch)
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, err)
	}
	defer func() { _ = tx.Rollback() }()
	res, err := tx.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash, granted_at)
		SELECT id, ?, ?, ? FROM automations WHERE id = ? AND approval_hash = ?
		ON CONFLICT (automation_id, tool) DO UPDATE SET grant_hash = excluded.grant_hash, granted_at = excluded.granted_at`,
		tool, hash, formatAutomationTime(now), automationID, hash)
	if err != nil {
		return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, err)
	}
	if n == 0 {
		return automationGrantRefusal(tx, automationID, tool)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, err)
	}
	return nil
}

// automationGrantRefusal tells a missing automation from a stale hash after a
// grant insert touched no row.
func automationGrantRefusal(tx *sql.Tx, automationID int64, tool string) error {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM automations WHERE id = ?`, automationID).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("automation %d: %w", automationID, ErrAutomationNotFound)
	case err != nil:
		return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, err)
	}
	return fmt.Errorf("granting %s to automation %d: %w", tool, automationID, ErrHashMismatch)
}

// DeleteAutomationToolGrant removes the grant of tool to automation
// automationID; false when there was none.
func (db *DB) DeleteAutomationToolGrant(automationID int64, tool string) (bool, error) {
	res, err := db.Exec(`DELETE FROM automation_tool_grants WHERE automation_id = ? AND tool = ?`, automationID, tool)
	if err != nil {
		return false, fmt.Errorf("removing the %s grant of automation %d: %w", tool, automationID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("removing the %s grant of automation %d: %w", tool, automationID, err)
	}
	return n > 0, nil
}

// ListAutomationToolGrants returns automation automationID's grants in tool
// order, inactive ones included (Active computed against approval_hash).
func (db *DB) ListAutomationToolGrants(automationID int64) ([]AutomationToolGrant, error) {
	rows, err := db.Query(`SELECT g.automation_id, g.tool, g.grant_hash, g.granted_at,
		g.grant_hash = a.approval_hash AND a.approval_hash <> ''
		FROM automation_tool_grants g JOIN automations a ON a.id = g.automation_id
		WHERE g.automation_id = ? ORDER BY g.tool`, automationID)
	if err != nil {
		return nil, fmt.Errorf("listing the grants of automation %d: %w", automationID, err)
	}
	defer func() { _ = rows.Close() }()
	var out []AutomationToolGrant
	for rows.Next() {
		var g AutomationToolGrant
		var grantedAt string
		if err := rows.Scan(&g.AutomationID, &g.Tool, &g.GrantHash, &grantedAt, &g.Active); err != nil {
			return nil, fmt.Errorf("listing the grants of automation %d: %w", automationID, err)
		}
		if g.GrantedAt, err = time.Parse(automationTimeLayout, grantedAt); err != nil {
			return nil, fmt.Errorf("automation %d grant %s granted_at %q: %w", automationID, g.Tool, grantedAt, err)
		}
		out = append(out, g)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the grants of automation %d: %w", automationID, err)
	}
	return out, nil
}

// ActiveAutomationToolGrant reports whether run runID's automation holds an
// active grant of tool: grant_hash = automations.approval_hash =
// automation_runs.recipe_hash, all non-empty. A run claimed before a recipe
// edit, another automation's run or a missing run never matches (spec §6.2,
// AGENT-03 exception).
func (db *DB) ActiveAutomationToolGrant(runID int64, tool string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM automation_runs r
		JOIN automations a ON a.id = r.automation_id
		JOIN automation_tool_grants g ON g.automation_id = r.automation_id AND g.tool = ?
		WHERE r.id = ? AND g.grant_hash = a.approval_hash AND g.grant_hash = r.recipe_hash
		  AND a.approval_hash <> ''`, tool, runID).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, fmt.Errorf("checking the %s grant of automation run %d: %w", tool, runID, err)
	}
	return true, nil
}
