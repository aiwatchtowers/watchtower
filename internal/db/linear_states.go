package db

import "fmt"

// LinearWorkflowState is one workflow state of a team (Todo, In Progress, …).
type LinearWorkflowState struct {
	AccountID int64
	TeamID    string
	ID        string
	Name      string
	Type      string
	Position  float64
}

// ReplaceLinearTeamStates replaces every mirrored workflow state of one team.
func (db *DB) ReplaceLinearTeamStates(accountID int64, teamID string, states []LinearWorkflowState) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("replacing linear states: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	if _, err := tx.Exec(`DELETE FROM linear_workflow_states WHERE account_id = ? AND team_id = ?`, accountID, teamID); err != nil {
		return fmt.Errorf("clearing linear states of team %s: %w", teamID, err)
	}
	for _, s := range states {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO linear_workflow_states (account_id, team_id, id, name, type, position)
			VALUES (?,?,?,?,?,?)`, accountID, teamID, s.ID, s.Name, s.Type, s.Position); err != nil {
			return fmt.Errorf("inserting linear state %s: %w", s.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("replacing linear states: %w", err)
	}
	return nil
}

// ListLinearTeamStates returns the team's workflow states, board order first.
func (db *DB) ListLinearTeamStates(accountID int64, teamID string) ([]LinearWorkflowState, error) {
	rows, err := db.Query(`SELECT account_id, team_id, id, name, type, position FROM linear_workflow_states
		WHERE account_id = ? AND team_id = ? ORDER BY position, name`, accountID, teamID)
	if err != nil {
		return nil, fmt.Errorf("listing linear states: %w", err)
	}
	defer rows.Close()
	var out []LinearWorkflowState
	for rows.Next() {
		var s LinearWorkflowState
		if err := rows.Scan(&s.AccountID, &s.TeamID, &s.ID, &s.Name, &s.Type, &s.Position); err != nil {
			return nil, fmt.Errorf("scanning linear state: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// LinearLabel is an issue label; TeamID "" marks a workspace label.
type LinearLabel struct {
	AccountID int64
	ID        string
	TeamID    string
	Name      string
}

// ReplaceLinearLabels replaces the labels of one team; teamID "" replaces the
// workspace labels.
func (db *DB) ReplaceLinearLabels(accountID int64, teamID string, labels []LinearLabel) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("replacing linear labels: %w", err)
	}
	defer tx.Rollback() // no-op after Commit
	if _, err := tx.Exec(`DELETE FROM linear_labels WHERE account_id = ? AND team_id = ?`, accountID, teamID); err != nil {
		return fmt.Errorf("clearing linear labels of team %q: %w", teamID, err)
	}
	for _, l := range labels {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO linear_labels (account_id, id, team_id, name) VALUES (?,?,?,?)`,
			accountID, l.ID, teamID, l.Name); err != nil {
			return fmt.Errorf("inserting linear label %s: %w", l.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("replacing linear labels: %w", err)
	}
	return nil
}

// ListLinearLabels returns the team's labels plus the workspace labels.
func (db *DB) ListLinearLabels(accountID int64, teamID string) ([]LinearLabel, error) {
	rows, err := db.Query(`SELECT account_id, id, team_id, name FROM linear_labels
		WHERE account_id = ? AND team_id IN (?, '') ORDER BY name, id`, accountID, teamID)
	if err != nil {
		return nil, fmt.Errorf("listing linear labels: %w", err)
	}
	defer rows.Close()
	var out []LinearLabel
	for rows.Next() {
		var l LinearLabel
		if err := rows.Scan(&l.AccountID, &l.ID, &l.TeamID, &l.Name); err != nil {
			return nil, fmt.Errorf("scanning linear label: %w", err)
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
