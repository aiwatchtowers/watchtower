package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Permission request statuses (permission_requests.status).
const (
	PermissionPending       = "pending"
	PermissionAllowed       = "allowed"
	PermissionDenied        = "denied"
	PermissionAnsweredOnMac = "answered_on_mac"
	PermissionExpired       = "expired"
)

// ErrPermissionRequestNotFound is GetPermissionRequest's answer for an unknown id.
var ErrPermissionRequestNotFound = errors.New("permission request not found")

// PermissionRequest is one permission prompt a PermissionRequest hook waits
// on (spec 2026-10-17-phone-permission-answers §4.1). Summary is what the
// owner approves (a Bash command, a file path, a URL, else the tool input
// as JSON, at most 2000 runes); nothing else of the tool input is stored.
// SummaryClipped says the summary was cut short: the phone offers Deny only.
type PermissionRequest struct {
	ID                int64
	TerminalSessionID int64
	WorkbenchID       int64
	ToolName          string
	Summary           string
	SummaryClipped    bool
	Status            string
	CreatedAt         time.Time
	DecidedAt         sql.NullString // agent-state stamp layout
	DecidedBy         sql.NullString // the phone's name; NULL otherwise
}

// OpenPermissionRequest records the session's agent state `approval` at time at
// (SetTerminalAgentState's own guarded UPDATE; a guard that holds the write
// back does not stop the request), then in one short transaction marks the
// session's older pending requests answered_on_mac (one prompt at a time per
// session) and inserts the new one pending. It returns the new row's id.
func (db *DB) OpenPermissionRequest(sessionRowID, workbenchID int64, sessionID string, toolName, summary string,
	summaryClipped bool, at time.Time, order AgentOrder) (int64, error) {
	if _, err := db.SetTerminalAgentState(sessionRowID, workbenchID, sessionID, "approval", at, "", nil, false, order); err != nil {
		return 0, fmt.Errorf("recording approval state for session %d: %w", sessionRowID, err)
	}
	stamp := AgentStateStamp(at)
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("opening permission request: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE permission_requests SET status = ?, decided_at = ?
		WHERE terminal_session_id = ? AND status = ?`,
		PermissionAnsweredOnMac, stamp, sessionRowID, PermissionPending); err != nil {
		return 0, fmt.Errorf("closing older permission requests of session %d: %w", sessionRowID, err)
	}
	res, err := tx.Exec(`INSERT INTO permission_requests
		(terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sessionRowID, workbenchID, toolName, summary, summaryClipped, PermissionPending, stamp)
	if err != nil {
		return 0, fmt.Errorf("inserting permission request: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading permission request id: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing permission request: %w", err)
	}
	return id, nil
}

// GetPermissionRequest reads one request; read-only. A created_at that is
// not an agent-state stamp is an error (Go writes only that layout).
func (db *DB) GetPermissionRequest(id int64) (*PermissionRequest, error) {
	var r PermissionRequest
	var created string
	err := db.QueryRow(`SELECT id, terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status,
		created_at, decided_at, decided_by FROM permission_requests WHERE id = ?`, id).
		Scan(&r.ID, &r.TerminalSessionID, &r.WorkbenchID, &r.ToolName, &r.Summary, &r.SummaryClipped, &r.Status,
			&created, &r.DecidedAt, &r.DecidedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPermissionRequestNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading permission request %d: %w", id, err)
	}
	var ok bool
	if r.CreatedAt, ok = ParseAgentStateStamp(created); !ok {
		return nil, fmt.Errorf("reading permission request %d: bad created_at %q", id, created)
	}
	return &r, nil
}

// ClosePermissionRequest sets a pending request to status, stamped at; false when
// it no longer is pending (compare-and-set: the first answer wins).
func (db *DB) ClosePermissionRequest(id int64, status string, at time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE permission_requests SET status = ?, decided_at = ?
		WHERE id = ? AND status = ?`, status, AgentStateStamp(at), id, PermissionPending)
	if err != nil {
		return false, fmt.Errorf("closing permission request %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("closing permission request %d: %w", id, err)
	}
	return n > 0, nil
}
