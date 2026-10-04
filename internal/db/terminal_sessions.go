package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var ErrTerminalSessionNotFound = errors.New("terminal session not found")

// agentStateAtLayout is agent_state_at's fixed-width UTC form: string order
// is time order, and the Desktop parses it pinned to UTC.
const agentStateAtLayout = "2006-01-02T15:04:05.000Z"

// agentStateAtGlob matches a stamp in agentStateAtLayout. A stored stamp that
// does not match never blocks a write: string order means nothing for it, and
// the next write replaces it with a valid one.
const agentStateAtGlob = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z"

// TerminalSession is the slice of a terminal_sessions row Go reads; the
// Desktop owns every other column but the agent state, which only the
// workbench hooks write.
type TerminalSession struct {
	ID              int64
	WorkbenchID     sql.NullInt64
	Kind            string
	Title           string
	TitleSource     string
	FolderPath      string
	ClaudeSessionID sql.NullString
	AgentState      sql.NullString
	AgentStateAt    time.Time     // zero when never reported
	AgentFailure    *AgentFailure // nil when the stored state is no StopFailure
	Finished        bool          // finished_at is set (finish_session)
	TurnEnd         sql.NullInt64 // agent_turn_end: the transcript's size at the run's last Stop hook
	ToolRun         bool          // agent_tool_run: a main-thread PostToolUse wrote the stored state
}

// AgentFailure flags a stored `waiting` as a turn that ended on an error (a
// StopFailure hook). At is agent_failed_at, the agent_state_at of the write
// that set it: a write stamps it with its own time, so At is read-only.
type AgentFailure struct {
	At    string
	Error string // the StopFailure error type, clipped by the hook; '' = unknown
}

func (db *DB) GetTerminalSession(id int64) (*TerminalSession, error) {
	var s TerminalSession
	var stateAt, failedAt sql.NullString
	var agentError string
	err := db.QueryRow(`SELECT id, project_id, kind, title, title_source, folder_path, claude_session_id,
		agent_state, agent_state_at, agent_failed_at, agent_error, finished_at IS NOT NULL,
		agent_turn_end, agent_tool_run
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID,
			&s.AgentState, &stateAt, &failedAt, &agentError, &s.Finished, &s.TurnEnd, &s.ToolRun)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTerminalSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d: %w", id, err)
	}
	// An unreadable stamp reads as never reported rather than failing the
	// row: the /clear id move and `terminal title` read it too, and the next
	// state write stores a valid stamp again.
	if stateAt.Valid {
		if at, perr := time.Parse(agentStateAtLayout, stateAt.String); perr == nil {
			s.AgentStateAt = at
		}
	}
	if failedAt.Valid {
		s.AgentFailure = &AgentFailure{At: failedAt.String, Error: agentError}
	}
	return &s, nil
}

// SetTerminalSessionAITitle stores an AI title only over a provisional one:
// an owner rename ('user') and an earlier AI title ('ai') are kept.
func (db *DB) SetTerminalSessionAITitle(id int64, title string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET title = ?, title_source = 'ai'
		WHERE id = ? AND title_source = 'auto'`, title, id)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	return n > 0, nil
}

// SetTerminalClaudeSessionID points project projectID's claude row id at the
// Claude Code conversation it now runs — the SessionStart hook after /clear
// or a resume that switched conversations, so the Desktop's next relaunch
// resumes it. The same column write as the Desktop's
// `TerminalSessionQueries.replaceClaudeSessionID`; false when the row is not
// that project's claude row or already holds sessionID.
func (db *DB) SetTerminalClaudeSessionID(id, projectID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET claude_session_id = ?
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id IS NOT ?`,
		sessionID, id, projectID, sessionID)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d claude session id: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d claude session id: %w", id, err)
	}
	return n > 0, nil
}

// ClearTerminalAgentState starts a new process run of workbench workbenchID's
// claude row id with no agent state — the SessionStart hook of a launch or a
// resume of conversation sessionID at at. Otherwise a new run whose first
// state equals the previous run's last one would be skipped as a repeat and
// keep the old run's time, which the Desktop does not trust. agent_state_at
// becomes at, not NULL, so a late async hook of the previous run (stamped
// earlier) still cannot land. A new run starts with no error and no turn
// order either. Same
// row guards as SetTerminalAgentState; false
// when there was no state to clear or a guard held it back.
func (db *DB) ClearTerminalAgentState(id, workbenchID int64, sessionID string, at time.Time) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = ?,
		agent_failed_at = NULL, agent_error = '', agent_turn_end = NULL, agent_tool_run = 0
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND agent_state IS NOT NULL
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`')`,
		stamp, id, workbenchID, sessionID, stamp)
	if err != nil {
		return false, fmt.Errorf("clearing terminal session %d agent state: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("clearing terminal session %d agent state: %w", id, err)
	}
	return n > 0, nil
}

// AgentOrder ties a state write to the turn it belongs to, for the two
// events whose hook start times can disagree with the turn order (board
// #368): a main-thread PostToolUse (async, so its process may start after
// the turn's sync Stop hook) and that Stop. The zero value is every other
// write.
type AgentOrder struct {
	// ToolRun marks a main-thread PostToolUse. Its write sets
	// agent_tool_run and lands only while agent_turn_end still is
	// SeenTurnEnd, the value the hook checked its tool call against: a Stop
	// since then ended the turn that ran the tool.
	ToolRun     bool
	SeenTurnEnd sql.NullInt64
	// Stop marks the sync Stop hook's write. It replaces a `working` a
	// main-thread PostToolUse wrote whatever that write's time: no main-thread
	// tool of a later turn runs before the Stop hook returns, so that
	// `working` is the ending turn's.
	Stop bool
}

// SetTerminalAgentState records what workbench workbenchID's claude row id is
// doing, reported by a Claude Code hook of conversation sessionID at at.
// failure is a StopFailure's error (nil for every other event): the write
// stores agent_failed_at = at and its Error, or clears both. prompt says the
// event is a UserPromptSubmit. A write that changes the state into `working`
// clears finished_at (finish_summary is kept): a new prompt, or a tool run
// out of waiting or approval — a turn the agent started itself. A `working`
// over a stored `working` clears it only for a prompt, never for a tool run:
// that is the finish_session turn itself. It writes only when the row still
// runs that conversation (a nested `claude -p` that inherited the row's env
// has another id), the state changes, a failure lands on a plain state or on
// one with another error, or a prompt's `working` lands on a finished row (a
// repeat keeps the transition time; a plain `waiting` — idle_prompt, the
// Stop hook — over a failed one keeps the error until a real state change),
// at is later than the stored time (a late async hook never overwrites a
// newer state; order.Stop over a tool run's `working` is the one exception,
// and keeps the later stored time), with onlyFrom set the stored state is
// onlyFrom, and order's turn guard holds. One guarded UPDATE, no
// transaction; false when a guard held it back.
func (db *DB) SetTerminalAgentState(id, workbenchID int64, sessionID, state string, at time.Time, onlyFrom string,
	failure *AgentFailure, prompt bool, order AgentOrder) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	var failedAt sql.NullString
	agentError, failed, fromPrompt, toolRun, stop := "", 0, 0, 0, 0
	if prompt {
		fromPrompt = 1
	}
	if failure != nil {
		failedAt = sql.NullString{String: stamp, Valid: true}
		agentError, failed = failure.Error, 1
	}
	if order.ToolRun {
		toolRun = 1
	}
	if order.Stop {
		stop = 1
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = ?,
		agent_state_at = CASE WHEN agent_state_at GLOB '`+agentStateAtGlob+`' AND agent_state_at > ?
		                      THEN agent_state_at ELSE ? END,
		agent_failed_at = ?, agent_error = ?, agent_tool_run = ?,
		finished_at = CASE WHEN ? = 'working' AND (agent_state IS NOT 'working' OR ? = 1)
		                   THEN NULL ELSE finished_at END
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND (agent_state IS NOT ? OR (? = 1 AND (agent_failed_at IS NULL OR agent_error IS NOT ?))
		       OR (? = 'working' AND ? = 1 AND finished_at IS NOT NULL))
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`'
		       OR (? = 1 AND agent_state = 'working' AND agent_tool_run = 1))
		  AND (? = '' OR agent_state = ?)
		  AND (? = 0 OR agent_turn_end IS ?)`,
		state, stamp, stamp, failedAt, agentError, toolRun, state, fromPrompt, id, workbenchID, sessionID, state, failed, agentError,
		state, fromPrompt, stamp, stop, onlyFrom, onlyFrom, toolRun, order.SeenTurnEnd)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	return n > 0, nil
}

// SetTerminalTurnEnd records that the sync Stop hook of conversation
// sessionID let a turn end when its transcript was end bytes long, on
// workbench workbenchID's claude row id (same row guards as
// SetTerminalAgentState). A main-thread PostToolUse whose tool call sits
// before it belongs to an ended turn. Written before the Stop's state write,
// and also when that write is a repeat (a turn without a prompt over a stored
// `waiting`). false when nothing changed or a guard held it back.
func (db *DB) SetTerminalTurnEnd(id, workbenchID int64, sessionID string, end int64) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_turn_end = ?
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND agent_turn_end IS NOT ?`,
		end, id, workbenchID, sessionID, end)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d turn end: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d turn end: %w", id, err)
	}
	return n > 0, nil
}
