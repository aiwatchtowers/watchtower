package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/agentkind"
)

var ErrTerminalSessionNotFound = errors.New("terminal session not found")

// agentStateAtLayout is agent_state_at's fixed-width UTC form: string order
// is time order, and the Desktop parses it pinned to UTC.
const agentStateAtLayout = "2006-01-02T15:04:05.000Z"

// AgentStateStamp is at the way agent_state_at and agent_background_at store
// it: compare-and-clear callers rebuild a stored stamp from its parsed time.
func AgentStateStamp(at time.Time) string { return at.UTC().Format(agentStateAtLayout) }

// ParseAgentStateStamp reads a stamp in agentStateAtLayout (agent_state_at,
// chat_question_at, owner_presence.seen_at); false when s is not one.
func ParseAgentStateStamp(s string) (time.Time, bool) {
	at, err := time.Parse(agentStateAtLayout, s)
	return at, err == nil
}

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
	ClaudeSessionID sql.NullString // the agent's own session id (Claude Code or Codex); NULL on a codex row until its first SessionStart
	TranscriptPath  sql.NullString // agent_transcript_path; read on codex rows only (Claude readers keep their own lookup)
	AgentState      sql.NullString
	AgentStateAt    time.Time     // zero when never reported
	AgentFailure    *AgentFailure // nil when the stored state is no StopFailure
	Finished        bool          // finished_at is set (finish_session)
	TurnEnd         sql.NullInt64 // agent_turn_end: the transcript's size at the run's last Stop hook
	ToolRun         bool          // agent_tool_run: a main-thread PostToolUse wrote the stored state
	Background      sql.NullInt64 // agent_background: in-flight background subagents; NULL = none / unknown
	BackgroundAt    time.Time     // agent_background_at; zero when NULL or unreadable
	ChatQuestionAt  string        // chat_question_at as stored; "" when there is no chat question
}

// AgentFailure flags a stored `waiting` as a turn that ended on an error (a
// StopFailure hook). At is agent_failed_at, the agent_state_at of the write
// that set it or, when a counted Stop kept the error, of that write: a write
// stamps it with its own time, so At is read-only.
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
		agent_turn_end, agent_tool_run, agent_background, agent_background_at,
		CASE WHEN chat_question IS NULL THEN '' ELSE COALESCE(chat_question_at, '') END
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.WorkbenchID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID,
			&s.AgentState, &stateAt, &failedAt, &agentError, &s.Finished, &s.TurnEnd, &s.ToolRun,
			&s.Background, &backgroundAt, &s.ChatQuestionAt)
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
	s.BackgroundAt = parsedStampOrZero(backgroundAt)
	if failedAt.Valid {
		s.AgentFailure = &AgentFailure{At: failedAt.String, Error: agentError}
	}
	// Only a codex row reads agent_transcript_path: a codex row exists only
	// once 00109 added the column, so the readers that open a database
	// without migrating it (`workbench asks`, the Claude hooks) keep working
	// on a 00108 database.
	if s.Kind == string(agentkind.Codex) {
		if err := db.QueryRow(`SELECT agent_transcript_path FROM terminal_sessions WHERE id = ?`, id).
			Scan(&s.TranscriptPath); err != nil {
			return nil, fmt.Errorf("reading terminal session %d transcript path: %w", id, err)
		}
	}
	return &s, nil
}

// AgentCwd is what a claude row records of its main agent's working
// directory (board #566), with the start of the run it belongs to.
type AgentCwd struct {
	Path     string    // agent_cwd; "" when unknown
	At       time.Time // agent_cwd_at; zero when NULL or unreadable
	RunStart time.Time // the run mark's stamp (agent_turns' since); zero when none or unreadable
}

// WouldRecord says a hook's cwd, reported at the time at, changes the
// stored one under SetTerminalAgentCwd's guards: a different, non-empty
// path, reported after the stored one (an unreadable stamp never blocks)
// and not before the run mark (a late async hook of the previous run).
func (c AgentCwd) WouldRecord(cwd string, at time.Time) bool {
	return cwd != "" && cwd != c.Path && (c.At.IsZero() || at.After(c.At)) &&
		(c.RunStart.IsZero() || !at.Before(c.RunStart))
}

// TerminalAgentCwd reads row id's working directory and its run's start
// (zero AgentCwd when the row is gone). Only the hooks need it, on a
// migrated database; GetTerminalSession leaves the columns out, so the
// readers that open a database without migrating it (`workbench asks`, the
// ask guard) never depend on 00110.
func (db *DB) TerminalAgentCwd(id int64) (AgentCwd, error) {
	var cwd, cwdAt, runStart sql.NullString
	err := db.QueryRow(`SELECT agent_cwd, agent_cwd_at, `+runStartExpr+`
		FROM terminal_sessions WHERE id = ?`, id).Scan(&cwd, &cwdAt, &runStart)
	if errors.Is(err, sql.ErrNoRows) {
		return AgentCwd{}, nil
	}
	if err != nil {
		return AgentCwd{}, fmt.Errorf("reading terminal session %d working directory: %w", id, err)
	}
	return AgentCwd{Path: cwd.String, At: parsedStampOrZero(cwdAt), RunStart: parsedStampOrZero(runStart)}, nil
}

// runStartExpr is the row's run mark stamp, agent_turns' since; NULL when
// agent_turns is NULL or not JSON (json_extract would fail on it).
const runStartExpr = `CASE WHEN json_valid(agent_turns) THEN json_extract(agent_turns, '$.since') END`

// parsedStampOrZero reads a nullable agentStateAtLayout column; zero when
// NULL or unreadable.
func parsedStampOrZero(stamp sql.NullString) time.Time {
	if !stamp.Valid {
		return time.Time{}
	}
	at, _ := ParseAgentStateStamp(stamp.String)
	return at
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

// SetTerminalClaudeSessionID points project projectID's agent row id at the
// conversation (Claude Code or Codex) it now runs — the SessionStart hook
// after /clear or a resume that switched conversations, so the Desktop's next relaunch
// resumes it. The same column write as the Desktop's
// `TerminalSessionQueries.replaceClaudeSessionID`; false when the row is not
// that project's agent row or already holds sessionID. The new conversation
// has its own transcript, so the turn order measured in the old one goes,
// and so do the background agent count (agent_background and
// agent_background_at) its Stop snapshotted, its agent turns (agent_turns),
// its chat question (chat_question, chat_question_at) and the old transcript's
// path (agent_transcript_path; the switch's SessionStart stores the new one).
// The working directory (agent_cwd, agent_cwd_at) stays: the same process
// switched conversations, it did not move.
func (db *DB) SetTerminalClaudeSessionID(id, projectID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = NULL,
		agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL, chat_question = NULL, chat_question_at = NULL,
		agent_turns = NULL
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id IS NOT ?`,
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

// SetTerminalAgentSessionID stores the session id a codex row's first
// SessionStart reported (Codex mints its own id, spec 2026-10-12 §5): it
// writes only over a NULL id on workbench workbenchID's codex row id, never
// moves an id once set (that is SetTerminalClaudeSessionID's switch path),
// and never touches a claude row. transcriptPath goes to
// agent_transcript_path ("" stores NULL). Like SetTerminalClaudeSessionID it
// clears the turn order, the background agent count, the agent turns and
// the chat question. false when a guard held it back or sessionID is "".
func (db *DB) SetTerminalAgentSessionID(id, workbenchID int64, sessionID, transcriptPath string) (bool, error) {
	if sessionID == "" {
		return false, nil
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = NULLIF(?, ''),
		agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL, chat_question = NULL, chat_question_at = NULL,
		agent_turns = NULL
		WHERE id = ? AND project_id = ? AND kind = 'codex' AND claude_session_id IS NULL`,
		sessionID, transcriptPath, id, workbenchID)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent session id: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d agent session id: %w", id, err)
	}
	return n > 0, nil
}

// SetTerminalTranscriptPath stores path, the transcript path a SessionStart
// of conversation sessionID reported, on workbench workbenchID's agent row
// id (either agent kind; only codex readers use it in v1). The row must
// still run sessionID. false when path is "", nothing changed or a guard
// held it back.
func (db *DB) SetTerminalTranscriptPath(id, workbenchID int64, sessionID, path string) (bool, error) {
	if path == "" {
		return false, nil
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_transcript_path = ?
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND agent_transcript_path IS NOT ?`,
		path, id, workbenchID, sessionID, path)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d transcript path: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d transcript path: %w", id, err)
	}
	return n > 0, nil
}

// MarkTerminalAgentRun starts a new process run of workbench workbenchID's
// agent row id — the SessionStart hook of a launch or a resume of
// conversation sessionID, stamped at — when the workbench's folder has the session
// state hooks: the previous run's state, error, turn order, background
// agent count (agent_background, agent_background_at), agent turns
// (agent_turns: its teammates and subagents died with the process; only the
// run's mark stays, so a late hook of the old run writes no turn back) and chat
// question (chat_question, chat_question_at) go, and
// agent_state_at becomes at even when nothing was stored. That stamp with no
// state is the run's mark: the hooks run, and the agent has not started a
// turn, so no permission dialog can be on screen (the Desktop's PROJ-12
// Return, board #396). It also keeps the new run's first state from being
// skipped as a repeat of the previous run's last one, and a late async hook
// of the previous run (stamped earlier) from landing. Same row guards as
// SetTerminalAgentState; false when a guard held it back or a newer stamp
// is stored. cwd is the new run's working directory (board #566), stored in
// agent_cwd stamped at; "" stores NULL in both cwd columns.
func (db *DB) MarkTerminalAgentRun(id, workbenchID int64, sessionID string, at time.Time, cwd string) (bool, error) {
	stamp := at.UTC().Format(agentStateAtLayout)
	var cwdValue, cwdAt sql.NullString
	if cwd != "" {
		cwdValue = sql.NullString{String: cwd, Valid: true}
		cwdAt = sql.NullString{String: stamp, Valid: true}
	}
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = ?,
		agent_failed_at = NULL, agent_error = '', agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL, chat_question = NULL, chat_question_at = NULL,
		agent_turns = json_object('since', ?), agent_cwd = ?, agent_cwd_at = ?
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`')`,
		stamp, stamp, cwdValue, cwdAt, id, workbenchID, sessionID, stamp)
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
// agent row id with no agent state when the folder lacks the session state
// hooks (with them, MarkTerminalAgentRun): no hook of this run will report,
// so agent_state_at becomes NULL — a stamp of this run would read as the
// run's mark (MarkTerminalAgentRun) and vouch for a state nobody reports. A
// late async hook of the previous run may still land, stamped before the
// run, which the Desktop does not trust. A new run starts with no error, no
// background agent count (agent_background, agent_background_at), no agent
// turns (agent_turns), no chat question (chat_question, chat_question_at), no
// working directory (agent_cwd, agent_cwd_at: no hook will report one) and
// no turn order either (the Desktop's Start fresh moves the id without
// resetting it, so a row with no state but a turn order, or with only a chat
// question or agent turns, is cleared too).
// Same row guards as SetTerminalAgentState; false when there was nothing to
// clear or a guard held it back.
func (db *DB) ClearTerminalAgentState(id, workbenchID int64, sessionID string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = NULL,
		agent_failed_at = NULL, agent_error = '', agent_turn_end = NULL, agent_tool_run = 0,
		agent_background = NULL, agent_background_at = NULL, chat_question = NULL, chat_question_at = NULL,
		agent_turns = NULL, agent_cwd = NULL, agent_cwd_at = NULL
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND (agent_state IS NOT NULL OR agent_state_at IS NOT NULL OR agent_turn_end IS NOT NULL OR agent_tool_run != 0
		       OR chat_question IS NOT NULL OR agent_turns IS NOT NULL OR agent_cwd IS NOT NULL OR agent_cwd_at IS NOT NULL)`,
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
	// Cwd is the main agent's working directory the hook reported (board
	// #566); "" = none. It rides in the write's UPDATE — agent_cwd and
	// agent_cwd_at take it and the write's time — only when the stored
	// agent_cwd_at is NULL, unreadable or earlier and the write is not before
	// the run mark (cwdNewerClause), and never makes a repeat
	// a change: a cwd alone goes through SetTerminalAgentCwd.
	Cwd string
}

// SetTerminalAgentState records what workbench workbenchID's agent row id is
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
// any plain `waiting` and agent_failed_at moves to the new agent_state_at
// (Error outranks background: the Desktop reads a row as failed only while
// the two match). One guarded UPDATE, no transaction; false when a
// guard held it back. order.Cwd rides along (see AgentOrder.Cwd); it never
// changes another column or whether the write lands.
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
		                       THEN CASE WHEN agent_state_at GLOB '`+agentStateAtGlob+`' AND agent_state_at > ?
		                                 THEN agent_state_at ELSE ? END
		                       ELSE ? END,
		agent_error = CASE WHEN ? = 0 AND ? = 'waiting' AND agent_state = 'waiting' AND agent_failed_at IS NOT NULL
		                   THEN agent_error ELSE ? END,
		agent_tool_run = ?,
		agent_background = CASE WHEN ? = 1 THEN agent_background ELSE ? END,
		agent_background_at = CASE WHEN ? = 1 THEN agent_background_at ELSE ? END,
		finished_at = CASE WHEN ? = 'working' AND (agent_state IS NOT 'working' OR ? = 1)
		                   THEN NULL ELSE finished_at END,
		agent_cwd = CASE WHEN `+cwdNewerClause+` THEN ? ELSE agent_cwd END,
		agent_cwd_at = CASE WHEN `+cwdNewerClause+` THEN ? ELSE agent_cwd_at END
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND (agent_state IS NOT ? OR (? = 1 AND (agent_failed_at IS NULL OR agent_error IS NOT ?))
		       OR (? = 'working' AND ? = 1 AND finished_at IS NOT NULL)
		       OR (? = 'waiting' AND agent_background IS NOT ?))
		  AND (agent_state_at IS NULL OR agent_state_at < ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`'
		       OR (? = 1 AND agent_state = 'working' AND agent_tool_run = 1))
		  AND (? = '' OR agent_state = ?)
		  AND (? = 0 OR agent_turn_end IS ?)`,
		state, stamp, stamp,
		failed, state, stamp, stamp, failedAt, failed, state, agentError,
		toolRun, keepBackground, background, keepBackground, backgroundAt,
		state, fromPrompt,
		order.Cwd, stamp, stamp, order.Cwd, order.Cwd, stamp, stamp, stamp,
		id, workbenchID, sessionID, state, failed, agentError,
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

// cwdNewerClause holds when a cwd (the first parameter; empty = none) stamped
// with the second and third parameters may replace the stored one:
// agent_cwd_at is NULL, unreadable or earlier, and the stamp is not before
// the run mark (a late async hook of the previous run, when the run's
// SessionStart reported no cwd and left agent_cwd_at NULL).
const cwdNewerClause = `(? != '' AND (agent_cwd_at IS NULL OR agent_cwd_at < ? OR agent_cwd_at NOT GLOB '` +
	agentStateAtGlob + `') AND COALESCE(` + runStartExpr + ` <= ?, 1))`

// SetTerminalAgentCwd records the main agent's working directory cwd,
// reported by a hook of conversation sessionID at at, on workbench
// workbenchID's agent row id (board #566) when no state write carries it:
// it writes only when cwd differs from agent_cwd, at is later than
// agent_cwd_at (an unreadable stamp never blocks) and not before the run
// mark (AgentCwd.WouldRecord), with
// SetTerminalAgentState's row guards, and changes agent_cwd and
// agent_cwd_at only. An empty cwd writes nothing. false when nothing
// changed or a guard held it back.
func (db *DB) SetTerminalAgentCwd(id, workbenchID int64, sessionID, cwd string, at time.Time) (bool, error) {
	if cwd == "" {
		return false, nil
	}
	stamp := AgentStateStamp(at)
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = ?
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND agent_cwd IS NOT ? AND `+cwdNewerClause,
		cwd, stamp, id, workbenchID, sessionID, cwd, cwd, stamp, stamp)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d working directory: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d working directory: %w", id, err)
	}
	return n > 0, nil
}

// LowerTerminalBackground records a later report about the background
// subagents the Stop counted on workbench workbenchID's agent row id (board
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
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
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
// workbenchID's agent row id on the staleness probe's verdict (board #411):
// it NULLs agent_background and agent_background_at only while the row is a
// counted `waiting` of conversation sessionID still stamped seenAt, the
// agent_background_at the probe read — a report or Stop that landed since
// wins. No other column changes, so the row reads its stored state again.
// false when a guard held it back.
func (db *DB) EndTerminalBackground(id, workbenchID int64, sessionID, seenAt string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_background = NULL, agent_background_at = NULL
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
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
// workbench workbenchID's agent row id (same row guards as
// SetTerminalAgentState). A main-thread PostToolUse whose tool call sits
// before it belongs to an ended turn. Written before the Stop's state write,
// and also when that write is a repeat (a turn without a prompt over a stored
// `waiting`). false when nothing changed or a guard held it back.
func (db *DB) SetTerminalTurnEnd(id, workbenchID int64, sessionID string, end int64) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET agent_turn_end = ?
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
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

// ErrChatQuestionNotRecorded is SetChatQuestion matching no row — the session is
// gone, runs another conversation, or holds a newer question.
var ErrChatQuestionNotRecorded = errors.New("chat question not recorded")

// chatQuestionStateTolerance bounds how long after the question the Stop's
// own `waiting` may be stamped and still be that turn end's (spec
// 2026-10-10-owner-asks-v2 Part 5.3, F9): the drift-check hook writes it in
// parallel with the ask guard's record. Its Swift twin is
// ChatQuestionEscalationPolicy.stateToleranceMillis (the Desktop's escalation
// decision): change both together.
const chatQuestionStateTolerance = 30 * time.Second

// ChatQuestion is a short question to the owner the Stop ask guard let
// through as terminal text (terminal_sessions.chat_question, JSON). Options
// holds 0 or 2-4 entries, already normalised by the guard.
type ChatQuestion struct {
	Question string               `json:"question"`
	Options  []ChatQuestionOption `json:"options"`
}

// ChatQuestionOption is one option the agent's message itself named.
type ChatQuestionOption struct {
	Label       string `json:"label"`
	Recommended bool   `json:"recommended"`
}

// SetChatQuestion records q, asked at the Stop of conversation
// claudeSessionID at at, on workbench workbenchID's agent row id. A newer
// Stop's question replaces an older one; an older one never replaces a newer
// one (an unreadable stored stamp never blocks). A Stop older than the row's
// run or turn is stale and records nothing: a run mark (no state) or a
// `working` stamped after at means the owner or a new run moved on since —
// the question would outlive the clear that run or prompt already did. A
// `waiting` or `approval` stamped after at does not refuse it: the Stop's own
// async state hook may land just after the guard's stamp. Nor does a
// main-thread tool run's `working` (agent_tool_run): its async PostToolUse
// may land after the Stop's moment, as SetTerminalAgentState's one
// exception allows. Only the two chat
// question columns change (PROJ-11). ErrChatQuestionNotRecorded when no row
// took it.
func (db *DB) SetChatQuestion(id, workbenchID int64, claudeSessionID string, q ChatQuestion, at time.Time) error {
	if q.Options == nil {
		q.Options = []ChatQuestionOption{}
	}
	body, err := json.Marshal(q)
	if err != nil {
		return fmt.Errorf("encoding chat question: %w", err)
	}
	stamp := AgentStateStamp(at)
	res, err := db.Exec(`UPDATE terminal_sessions SET chat_question = ?, chat_question_at = ?
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ?
		  AND (chat_question_at IS NULL OR chat_question_at < ? OR chat_question_at NOT GLOB '`+agentStateAtGlob+`')
		  AND (agent_state IN ('waiting', 'approval') OR (agent_state = 'working' AND agent_tool_run = 1)
		       OR agent_state_at IS NULL OR agent_state_at <= ? OR agent_state_at NOT GLOB '`+agentStateAtGlob+`')`,
		string(body), stamp, id, workbenchID, claudeSessionID, stamp, stamp)
	if err != nil {
		return fmt.Errorf("recording terminal session %d chat question: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("recording terminal session %d chat question: %w", id, err)
	}
	if n == 0 {
		return fmt.Errorf("terminal session %d: %w", id, ErrChatQuestionNotRecorded)
	}
	return nil
}

// ClearChatQuestionBefore clears workbench workbenchID's agent row id's chat
// question when the row runs conversation claudeSessionID and the question
// was recorded before eventAt (a later Stop that records none, the owner's
// next prompt, a turn the agent started itself); a newer question stays. An unreadable
// stored stamp is cleared: it can never be raised. Only the two chat
// question columns change (PROJ-11); nothing to clear is no error.
func (db *DB) ClearChatQuestionBefore(id, workbenchID int64, claudeSessionID string, eventAt time.Time) error {
	stamp := AgentStateStamp(eventAt)
	if _, err := db.Exec(`UPDATE terminal_sessions SET chat_question = NULL, chat_question_at = NULL
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND claude_session_id = ? AND chat_question_at IS NOT NULL
		  AND (chat_question_at < ? OR chat_question_at NOT GLOB '`+agentStateAtGlob+`')`,
		id, workbenchID, claudeSessionID, stamp); err != nil {
		return fmt.Errorf("clearing terminal session %d chat question: %w", id, err)
	}
	return nil
}

// TakeChatQuestion is the escalation's compare-and-take inside the caller's
// write transaction (spec Part 5.3, F9): it returns workbench workbenchID's
// agent row id's chat question and clears it only while chat_question_at is
// still at (not cleared, not replaced), agent_state is `waiting` and
// agent_state_at is at most 30 s after the question — the Stop's own
// `waiting`, written by the parallel drift-check hook, may be stamped just
// after the guard's record. There is no lower bound: a `waiting` older than
// the question, with no later `working` or run mark, means the agent has not
// acted since (a repeated state keeps its first stamp, PROJ-11), so the
// question is still the live one. Otherwise nil and nothing written.
// ErrTerminalSessionNotFound for a missing row, ErrNotInWorkbench for a row
// of another workbench or a shell row (nothing written either).
func (db *DB) TakeChatQuestion(tx *sql.Tx, id, workbenchID int64, at string) (*ChatQuestion, error) {
	var body, questionAt, state, stateAt sql.NullString
	var mine bool
	err := tx.QueryRow(`SELECT chat_question, chat_question_at, agent_state, agent_state_at,
		project_id IS ? AND kind IN `+agentkind.SQLKinds()+`
		FROM terminal_sessions WHERE id = ?`, workbenchID, id).Scan(&body, &questionAt, &state, &stateAt, &mine)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTerminalSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d chat question: %w", id, err)
	}
	if !mine {
		return nil, fmt.Errorf("terminal session %d is not an agent session of workbench %d: %w", id, workbenchID, ErrNotInWorkbench)
	}
	if !body.Valid || questionAt.String != at || state.String != "waiting" || !stateAt.Valid {
		return nil, nil
	}
	asked, ok := ParseAgentStateStamp(questionAt.String)
	if !ok {
		return nil, nil
	}
	if stateTime, ok := ParseAgentStateStamp(stateAt.String); !ok || stateTime.After(asked.Add(chatQuestionStateTolerance)) {
		return nil, nil
	}
	var q ChatQuestion
	if err := json.Unmarshal([]byte(body.String), &q); err != nil {
		return nil, fmt.Errorf("decoding terminal session %d chat question: %w", id, err)
	}
	//nolint:gosec // G202: agentkind.SQLKinds() is a constant list; every value is a bound arg.
	res, err := tx.Exec(`UPDATE terminal_sessions SET chat_question = NULL, chat_question_at = NULL
		WHERE id = ? AND project_id = ? AND kind IN `+agentkind.SQLKinds()+` AND chat_question_at = ?`, id, workbenchID, at)
	if err != nil {
		return nil, fmt.Errorf("taking terminal session %d chat question: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, fmt.Errorf("taking terminal session %d chat question: %w", id, err)
	}
	if n != 1 {
		return nil, nil
	}
	return &q, nil
}
