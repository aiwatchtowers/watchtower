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

// AgentStateStamp is at the way agent_state_at and agent_background_at store
// it: compare-and-clear callers rebuild a stored stamp from its parsed time.
func AgentStateStamp(at time.Time) string { return at.UTC().Format(agentStateAtLayout) }

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
	Background      sql.NullInt64 // agent_background: in-flight background subagents; NULL = none / unknown
	BackgroundAt    time.Time     // agent_background_at; zero when NULL or unreadable
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
	var stateAt, failedAt, backgroundAt sql.NullString
	var agentError string
	err := db.QueryRow(`SELECT id, project_id, kind, title, title_source, folder_path, claude_session_id,
		agent_state, agent_state_at, agent_failed_at, agent_error, finished_at IS NOT NULL,
		agent_turn_end, agent_tool_run, agent_background, agent_background_at
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID,
			&s.AgentState, &stateAt, &failedAt, &agentError, &s.Finished, &s.TurnEnd, &s.ToolRun,
			&s.Background, &backgroundAt)
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
	if backgroundAt.Valid {
		if at, perr := time.Parse(agentStateAtLayout, backgroundAt.String); perr == nil {
			s.BackgroundAt = at
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
// that project's claude row or already holds sessionID. The new conversation
// has its own transcript, so the turn order measured in the old one goes,
// and so does the background agent count (agent_background and
// agent_background_at) its Stop snapshotted.
func (db *DB) SetTerminalClaudeSessionID(id, projectID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET claude_session_id = ?, agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL
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

// MarkTerminalAgentRun starts a new process run of workbench workbenchID's
// claude row id — the SessionStart hook of a launch or a resume of
// conversation sessionID, stamped at — when the workbench's folder has the session
// state hooks: the previous run's state, error, turn order and background
// agent count (agent_background, agent_background_at) go, and
// agent_state_at becomes at even when nothing was stored. That stamp with no
// state is the run's mark: the hooks run, and the agent has not started a
// turn, so no permission dialog can be on screen (the Desktop's PROJ-12
// Return, board #396). It also keeps the new run's first state from being
// skipped as a repeat of the previous run's last one, and a late async hook
// of the previous run (stamped earlier) from landing. Same row guards as
// SetTerminalAgentState; false when a guard held it back or a newer stamp
// is stored.
func (db *DB) MarkTerminalAgentRun(id, workbenchID int64, sessionID string, at time.Time) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = ?,
		agent_failed_at = NULL, agent_error = '', agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`')`,
		stamp, id, workbenchID, sessionID, stamp)
	if err != nil {
		return false, fmt.Errorf("marking terminal session %d's new run: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("marking terminal session %d's new run: %w", id, err)
	}
	return n > 0, nil
}

// ClearTerminalAgentState starts a new process run of workbench workbenchID's
// claude row id with no agent state when the folder lacks the session state
// hooks (with them, MarkTerminalAgentRun): no hook of this run will report,
// so agent_state_at becomes NULL — a stamp of this run would read as the
// run's mark (MarkTerminalAgentRun) and vouch for a state nobody reports. A
// late async hook of the previous run may still land, stamped before the
// run, which the Desktop does not trust. A new run starts with no error, no
// background agent count (agent_background, agent_background_at) and no
// turn order either (the Desktop's Start fresh moves the id without
// resetting it, so a row with no state but a turn order is cleared too).
// Same row guards as SetTerminalAgentState; false when there was nothing to
// clear or a guard held it back.
func (db *DB) ClearTerminalAgentState(id, workbenchID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = NULL,
		agent_failed_at = NULL, agent_error = '', agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND (agent_state IS NOT NULL OR agent_state_at IS NOT NULL OR agent_turn_end IS NOT NULL OR agent_tool_run != 0)`,
		id, workbenchID, sessionID)
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
	// Background is the Stop's snapshot of in-flight background subagents
	// (board #411), read only when Stop is set: a positive count is stored
	// in agent_background with agent_background_at = the write's time;
	// zero or invalid (none / unknown) stores NULL in both. Only this write
	// raises agent_background from NULL; every other write keeps, lowers
	// (LowerTerminalBackground) or NULLs it.
	Background sql.NullInt64
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
// onlyFrom, and order's turn guard holds. The background agent count
// (board #411) follows the state: a `working` NULLs agent_background and
// agent_background_at (a main turn began, or a subagent's tool result
// outranks background); the Stop's `waiting` stores order.Background
// stamped at (on the order.Stop override of a tool run's `working`,
// agent_background_at is the Stop's own at while agent_state_at keeps the
// later stored time); any other `waiting` (StopFailure, idle_prompt) NULLs
// both; an `approval` keeps both. A `waiting` whose count differs from the stored
// one is a change, not a repeat, and advances agent_state_at; when only
// that let it through over a failed `waiting`, the error is kept as by
// any plain `waiting`. One guarded UPDATE, no transaction; false when a
// guard held it back.
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
	// keepBackground: an `approval` keeps the count; otherwise the write
	// stores background (NULL unless the Stop counted some) stamped at.
	keepBackground := 0
	var background sql.NullInt64
	var backgroundAt sql.NullString
	switch {
	case state == "approval":
		keepBackground = 1
	case state == "waiting" && order.Stop && order.Background.Valid && order.Background.Int64 > 0:
		background = order.Background
		backgroundAt = sql.NullString{String: stamp, Valid: true}
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = ?,
		agent_state_at = CASE WHEN agent_state_at GLOB '`+agentStateAtGlob+`' AND agent_state_at > ?
		                      THEN agent_state_at ELSE ? END,
		agent_failed_at = CASE WHEN ? = 0 AND ? = 'waiting' AND agent_state = 'waiting' AND agent_failed_at IS NOT NULL
		                       THEN agent_failed_at ELSE ? END,
		agent_error = CASE WHEN ? = 0 AND ? = 'waiting' AND agent_state = 'waiting' AND agent_failed_at IS NOT NULL
		                   THEN agent_error ELSE ? END,
		agent_tool_run = ?,
		agent_background = CASE WHEN ? = 1 THEN agent_background ELSE ? END,
		agent_background_at = CASE WHEN ? = 1 THEN agent_background_at ELSE ? END,
		finished_at = CASE WHEN ? = 'working' AND (agent_state IS NOT 'working' OR ? = 1)
		                   THEN NULL ELSE finished_at END
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND (agent_state IS NOT ? OR (? = 1 AND (agent_failed_at IS NULL OR agent_error IS NOT ?))
		       OR (? = 'working' AND ? = 1 AND finished_at IS NOT NULL)
		       OR (? = 'waiting' AND agent_background IS NOT ?))
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`'
		       OR (? = 1 AND agent_state = 'working' AND agent_tool_run = 1))
		  AND (? = '' OR agent_state = ?)
		  AND (? = 0 OR agent_turn_end IS ?)`,
		state, stamp, stamp,
		failed, state, failedAt, failed, state, agentError,
		toolRun, keepBackground, background, keepBackground, backgroundAt,
		state, fromPrompt, id, workbenchID, sessionID, state, failed, agentError,
		state, fromPrompt, state, background, stamp, stop, onlyFrom, onlyFrom, toolRun, order.SeenTurnEnd)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent state: %w", id, err)
	}
	return n > 0, nil
}

// LowerTerminalBackground records a later report about the background
// subagents the Stop counted on workbench workbenchID's claude row id (board
// #411), from a hook of conversation sessionID at at: a subagent's tool
// result (count nil, a heartbeat) or a SubagentStop (count = the subagents
// its snapshot still lists). It sets agent_background_at = at and, with
// count, agent_background = the lower of the stored count and *count — it
// never raises the count and never starts one. It writes only over a
// `waiting` with a positive count whose agent_background_at is earlier than
// at (an unreadable stamp never blocks), with SetTerminalAgentState's row
// guards; no other column changes. false when a guard held it back.
func (db *DB) LowerTerminalBackground(id, workbenchID int64, sessionID string, at time.Time, count *int64) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	var lower sql.NullInt64
	if count != nil {
		lower = sql.NullInt64{Int64: *count, Valid: true}
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_background_at = ?,
		agent_background = CASE WHEN ? IS NULL THEN agent_background ELSE MIN(agent_background, ?) END
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND agent_state = 'waiting' AND agent_background > 0
		  AND (agent_background_at IS NULL OR agent_background_at < ? OR agent_background_at NOT GLOB '`+agentStateAtGlob+`')`,
		stamp, lower, lower, id, workbenchID, sessionID, stamp)
	if err != nil {
		return false, fmt.Errorf("lowering terminal session %d background agents: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("lowering terminal session %d background agents: %w", id, err)
	}
	return n > 0, nil
}

// EndTerminalBackground ends the background subagent count of workbench
// workbenchID's claude row id on the staleness probe's verdict (board #411):
// it NULLs agent_background and agent_background_at only while the row is a
// counted `waiting` of conversation sessionID still stamped seenAt, the
// agent_background_at the probe read — a report or Stop that landed since
// wins. No other column changes, so the row reads its stored state again.
// false when a guard held it back.
func (db *DB) EndTerminalBackground(id, workbenchID int64, sessionID, seenAt string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_background = NULL, agent_background_at = NULL
		WHERE id = ? AND project_id = ? AND kind = 'claude' AND claude_session_id = ?
		  AND agent_state = 'waiting' AND agent_background IS NOT NULL AND agent_background_at = ?`,
		id, workbenchID, sessionID, seenAt)
	if err != nil {
		return false, fmt.Errorf("ending terminal session %d background agents: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("ending terminal session %d background agents: %w", id, err)
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
