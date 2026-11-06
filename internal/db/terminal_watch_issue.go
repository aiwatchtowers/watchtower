package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Watch issues (migration 00173): why the session host's codex rollout watch
// cannot read a working codex row's rollout (spec 2026-11-05 §3.5). The class
// only; never a path (FILES-01).
const (
	WatchIssueMissing    = "missing"
	WatchIssuePermission = "permission"
	WatchIssueCompressed = "compressed"
	WatchIssueUnreadable = "unreadable"
)

// validWatchIssue says issue is one of the four classes.
func validWatchIssue(issue string) bool {
	switch issue {
	case WatchIssueMissing, WatchIssuePermission, WatchIssueCompressed, WatchIssueUnreadable:
		return true
	}
	return false
}

// SetAgentWatchIssue marks terminal row id as not watched for issue, stamped
// at: only over a codex row that reads `working`, is not finished and carries
// no failure (a failure the pull read wins), and only when the stored issue
// differs, so a repeat is false and a caller logs one line per row and issue.
func (db *DB) SetAgentWatchIssue(id int64, issue string, at time.Time) (bool, error) {
	if !validWatchIssue(issue) {
		return false, fmt.Errorf("terminal session %d: unknown watch issue %q", id, issue)
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_watch_issue = ?, agent_watch_issue_at = ?
		WHERE id = ? AND kind = 'codex' AND agent_state = 'working' AND finished_at IS NULL
		  AND agent_failed_at IS NULL AND agent_watch_issue IS NOT ?`,
		issue, AgentStateStamp(at), id, issue)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d watch issue: %w", id, err)
	}
	return rowsChanged(res, fmt.Sprintf("setting terminal session %d watch issue", id))
}

// ClearAgentWatchIssue clears row id's watch issue: the next hook event of
// the row says the agent is heard again, and the watch re-arms. false when
// there was none. Every codex hook calls it and the issue is almost always
// unset, so it reads first and takes the write lock only to clear one.
func (db *DB) ClearAgentWatchIssue(id int64) (bool, error) {
	var set bool
	err := db.QueryRow(`SELECT agent_watch_issue IS NOT NULL FROM terminal_sessions WHERE id = ?`, id).Scan(&set)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !set) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading terminal session %d watch issue: %w", id, err)
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_watch_issue = NULL, agent_watch_issue_at = NULL
		WHERE id = ? AND agent_watch_issue IS NOT NULL`, id)
	if err != nil {
		return false, fmt.Errorf("clearing terminal session %d watch issue: %w", id, err)
	}
	return rowsChanged(res, fmt.Sprintf("clearing terminal session %d watch issue", id))
}

// CodexWatchRow is what the session host's rollout watch reads of a row on
// each tick.
type CodexWatchRow struct {
	ID             int64
	WorkbenchID    int64
	Kind           string // terminal_sessions.kind
	State          string // agent_state; "" = none
	StateAt        time.Time
	Finished       bool
	Failed         bool // agent_failed_at is set
	SessionID      string
	TranscriptPath string
	WatchIssue     string // "" = none
}

// GetCodexWatchRow reads row id for the rollout watch;
// ErrTerminalSessionNotFound when it is gone.
func (db *DB) GetCodexWatchRow(id int64) (CodexWatchRow, error) {
	var (
		r                                CodexWatchRow
		wb                               sql.NullInt64
		state, stateAt, sid, path, issue sql.NullString
	)
	err := db.QueryRow(`SELECT project_id, kind, agent_state, agent_state_at, finished_at IS NOT NULL,
		agent_failed_at IS NOT NULL, claude_session_id, agent_transcript_path, agent_watch_issue
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&wb, &r.Kind, &state, &stateAt, &r.Finished, &r.Failed, &sid, &path, &issue)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrTerminalSessionNotFound
	}
	if err != nil {
		return r, fmt.Errorf("reading terminal session %d for the watch: %w", id, err)
	}
	r.ID, r.WorkbenchID = id, wb.Int64
	r.State, r.SessionID, r.TranscriptPath, r.WatchIssue = state.String, sid.String, path.String, issue.String
	r.StateAt = parsedStampOrZero(stateAt)
	return r, nil
}
