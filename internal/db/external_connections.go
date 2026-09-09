package db

import (
	"encoding/json"
	"fmt"
)

// ExternalConnection is one row of external_connections — an owner-managed
// external MCP server ("Quick Connections"). Read-only tools surfaced in the
// chat on demand; nothing is synced. See migration 00064.
type ExternalConnection struct {
	ID        int64
	Name      string
	Kind      string // "stdio" | "http"
	Command   string
	Args      []string // decoded from args_json
	URL       string
	Enabled   bool
	Status    string
	Error     string
	CreatedAt string
}

// externalConnectionColumns is the shared column list for
// ListExternalConnections, ListEnabledExternalConnections, and
// GetExternalConnection — one place to keep the SELECT list and
// scanExternalConnection's Scan targets in lockstep.
const externalConnectionColumns = `id, name, kind, command, args_json, url,
        enabled, status, error, created_at`

// scanExternalConnection scans one externalConnectionColumns row from either
// *sql.Row or *sql.Rows (the slack_accounts.scanSlackAccount precedent),
// decoding args_json into Args.
func scanExternalConnection(scanner interface{ Scan(dest ...any) error }) (ExternalConnection, error) {
	var c ExternalConnection
	var argsJSON string
	err := scanner.Scan(&c.ID, &c.Name, &c.Kind, &c.Command, &argsJSON, &c.URL,
		&c.Enabled, &c.Status, &c.Error, &c.CreatedAt)
	if err != nil {
		return ExternalConnection{}, err
	}
	// args_json is NOT NULL DEFAULT '[]' — never empty, so no guard needed.
	if err := json.Unmarshal([]byte(argsJSON), &c.Args); err != nil {
		return ExternalConnection{}, fmt.Errorf("decoding args_json: %w", err)
	}
	return c, nil
}

// InsertExternalConnection inserts a new external connection and returns its
// ID. Fails with a UNIQUE constraint error on a duplicate name.
func (db *DB) InsertExternalConnection(c ExternalConnection) (int64, error) {
	argsJSON, err := json.Marshal(c.Args)
	if err != nil {
		return 0, fmt.Errorf("encoding args_json: %w", err)
	}
	res, err := db.Exec(`INSERT INTO external_connections
        (name, kind, command, args_json, url, enabled)
        VALUES (?,?,?,?,?,?)`,
		c.Name, c.Kind, c.Command, string(argsJSON), c.URL, c.Enabled)
	if err != nil {
		return 0, fmt.Errorf("inserting external connection: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading new external connection id: %w", err)
	}
	return id, nil
}

// ListExternalConnections returns every external connection, oldest first.
func (db *DB) ListExternalConnections() ([]ExternalConnection, error) {
	rows, err := db.Query(`SELECT ` + externalConnectionColumns + ` FROM external_connections ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing external connections: %w", err)
	}
	defer rows.Close()
	var out []ExternalConnection
	for rows.Next() {
		c, err := scanExternalConnection(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning external connection: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ListEnabledExternalConnections returns every enabled external connection,
// oldest first.
func (db *DB) ListEnabledExternalConnections() ([]ExternalConnection, error) {
	rows, err := db.Query(`SELECT ` + externalConnectionColumns + ` FROM external_connections WHERE enabled = 1 ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("listing enabled external connections: %w", err)
	}
	defer rows.Close()
	var out []ExternalConnection
	for rows.Next() {
		c, err := scanExternalConnection(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning external connection: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetExternalConnection returns a single external connection by ID.
func (db *DB) GetExternalConnection(id int64) (ExternalConnection, error) {
	c, err := scanExternalConnection(db.QueryRow(`SELECT `+externalConnectionColumns+` FROM external_connections WHERE id = ?`, id))
	if err != nil {
		return ExternalConnection{}, fmt.Errorf("getting external connection %d: %w", id, err)
	}
	return c, nil
}

// SetExternalConnectionEnabled toggles whether id's tools are surfaced.
func (db *DB) SetExternalConnectionEnabled(id int64, enabled bool) error {
	res, err := db.Exec(`UPDATE external_connections SET enabled = ? WHERE id = ?`, enabled, id)
	if err != nil {
		return fmt.Errorf("setting enabled for external connection %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting enabled: no external_connections row %d", id)
	}
	return nil
}

// RemoveExternalConnection deletes id's row outright — a hard delete, unlike
// the Slack/Jira "remove" precedent, since a Quick Connection carries no
// synced data that needs to stay reachable.
func (db *DB) RemoveExternalConnection(id int64) error {
	res, err := db.Exec(`DELETE FROM external_connections WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("removing external connection %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("removing external connection: no external_connections row %d", id)
	}
	return nil
}
