package db

import (
	"database/sql"
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
	// Tools is the cached tools/list (external_connection_tools, migration
	// 00093); ToolsListed is false
	// until a list was taken, in which case the chat allows none of the
	// server's tools (QC-02, fail closed).
	Tools         []ExternalTool
	ToolsListed   bool
	ToolsListedAt string
	// ToolsListFailedAt is the last failed tools/list ('' = none since the
	// last success), so a chat launch can back off a dead server.
	ToolsListFailedAt string
	// AllowTools is the owner's explicit allow list of tool names; nil (SQL
	// NULL) means the default policy — only tools known to be read-only.
	AllowTools []string
}

// ExternalTool is one tool from an external server's tools/list, with the
// facts the QC-02 policy needs: whether the server annotated it at all and
// whether it declared it read-only.
type ExternalTool struct {
	Name         string `json:"name"`
	ReadOnlyHint bool   `json:"read_only_hint"`
	Annotated    bool   `json:"annotated"`
}

// externalConnectionColumns is the shared column list for
// ListExternalConnections, ListEnabledExternalConnections, and
// GetExternalConnection — one place to keep the SELECT list and
// scanExternalConnection's Scan targets in lockstep.
const externalConnectionColumns = `c.id, c.name, c.kind, c.command, c.args_json, c.url,
        c.enabled, c.status, c.error, c.created_at,
        COALESCE(t.tools_json, ''), COALESCE(t.listed_at, ''), t.allow_json,
        COALESCE(t.list_failed_at, '')`

// externalConnectionFrom joins each connection to its QC-02 tool row (absent
// = never listed, no allow list).
const externalConnectionFrom = ` FROM external_connections c
        LEFT JOIN external_connection_tools t ON t.connection_id = c.id`

// scanExternalConnection scans one externalConnectionColumns row from either
// *sql.Row or *sql.Rows (the slack_accounts.scanSlackAccount precedent),
// decoding args_json into Args.
func scanExternalConnection(scanner interface{ Scan(dest ...any) error }) (ExternalConnection, error) {
	var c ExternalConnection
	var argsJSON, toolsJSON string
	var allowJSON sql.NullString
	err := scanner.Scan(&c.ID, &c.Name, &c.Kind, &c.Command, &argsJSON, &c.URL,
		&c.Enabled, &c.Status, &c.Error, &c.CreatedAt, &toolsJSON, &c.ToolsListedAt, &allowJSON, &c.ToolsListFailedAt)
	if err != nil {
		return ExternalConnection{}, err
	}
	// args_json is NOT NULL DEFAULT '[]' — never empty, so no guard needed.
	if err := json.Unmarshal([]byte(argsJSON), &c.Args); err != nil {
		return ExternalConnection{}, fmt.Errorf("decoding args_json: %w", err)
	}
	if toolsJSON != "" {
		if err := json.Unmarshal([]byte(toolsJSON), &c.Tools); err != nil {
			return ExternalConnection{}, fmt.Errorf("decoding tools_json: %w", err)
		}
		c.ToolsListed = true
	}
	if allowJSON.Valid {
		c.AllowTools = []string{}
		if err := json.Unmarshal([]byte(allowJSON.String), &c.AllowTools); err != nil {
			return ExternalConnection{}, fmt.Errorf("decoding allow_json: %w", err)
		}
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
	rows, err := db.Query(`SELECT ` + externalConnectionColumns + externalConnectionFrom + ` ORDER BY c.id ASC`)
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
	rows, err := db.Query(`SELECT ` + externalConnectionColumns + externalConnectionFrom + ` WHERE c.enabled = 1 ORDER BY c.id ASC`)
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
	c, err := scanExternalConnection(db.QueryRow(`SELECT `+externalConnectionColumns+externalConnectionFrom+` WHERE c.id = ?`, id))
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

// SetExternalConnectionStatus records id's health (e.g. "ok"/"revoked") and
// an accompanying error message, cleared by passing an empty string.
func (db *DB) SetExternalConnectionStatus(id int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE external_connections SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting status for external connection %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no external_connections row with id %d", id)
	}
	return nil
}

// MarkExternalConnectionOKIf flips id's row to ok only while it still holds
// status/errMsg — the values the caller read before its work — so a newer
// status another process recorded meanwhile is never overwritten. Reports
// whether the row changed.
func (db *DB) MarkExternalConnectionOKIf(id int64, status, errMsg string) (bool, error) {
	res, err := db.Exec(`UPDATE external_connections SET status = 'ok', error = ''
        WHERE id = ? AND status = ? AND error = ? AND status != 'ok'`, id, status, errMsg)
	if err != nil {
		return false, fmt.Errorf("marking external connection %d ok: %w", id, err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
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

// SetExternalConnectionTools caches id's tools/list (QC-02) and when it was
// taken. A nil list is stored as [] — a listed server with no tools, distinct
// from never listed. Fails on an unknown id (foreign key).
func (db *DB) SetExternalConnectionTools(id int64, tools []ExternalTool, listedAt string) error {
	if tools == nil {
		tools = []ExternalTool{}
	}
	data, err := json.Marshal(tools)
	if err != nil {
		return fmt.Errorf("encoding tools_json: %w", err)
	}
	_, err = db.Exec(`INSERT INTO external_connection_tools (connection_id, tools_json, listed_at)
        VALUES (?, ?, ?)
        ON CONFLICT(connection_id) DO UPDATE SET tools_json = excluded.tools_json, listed_at = excluded.listed_at,
            list_failed_at = ''`,
		id, string(data), listedAt)
	if err != nil {
		return fmt.Errorf("caching tools for external connection %d: %w", id, err)
	}
	return nil
}

// SetExternalConnectionAllowTools sets the owner's explicit allow list of
// tool names for id; nil clears it back to the default policy (SQL NULL).
func (db *DB) SetExternalConnectionAllowTools(id int64, names []string) error {
	var value any // nil → NULL
	if names != nil {
		data, err := json.Marshal(names)
		if err != nil {
			return fmt.Errorf("encoding allow_json: %w", err)
		}
		value = string(data)
	}
	_, err := db.Exec(`INSERT INTO external_connection_tools (connection_id, allow_json)
        VALUES (?, ?)
        ON CONFLICT(connection_id) DO UPDATE SET allow_json = excluded.allow_json`,
		id, value)
	if err != nil {
		return fmt.Errorf("setting allowed tools for external connection %d: %w", id, err)
	}
	return nil
}

// SetExternalConnectionListFailed records a failed tools/list for id at at,
// leaving any earlier successful listing in place.
func (db *DB) SetExternalConnectionListFailed(id int64, at string) error {
	_, err := db.Exec(`INSERT INTO external_connection_tools (connection_id, list_failed_at)
        VALUES (?, ?)
        ON CONFLICT(connection_id) DO UPDATE SET list_failed_at = excluded.list_failed_at`,
		id, at)
	if err != nil {
		return fmt.Errorf("recording failed tool listing for external connection %d: %w", id, err)
	}
	return nil
}
