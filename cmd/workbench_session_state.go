package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/terminal"
)

// Agent states a terminal_sessions row records (the migration's CHECK).
const (
	agentStateWorking  = "working"
	agentStateWaiting  = "waiting"
	agentStateApproval = "approval"
)

// sessionStateInputWait bounds the wait for the hook input: Claude Code
// writes it and closes stdin at once. A var for tests.
var sessionStateInputWait = time.Second

// sessionStateStdinLimit caps what the state hook reads of its input. Far
// above hookStdinLimit: a PostToolUse input carries the tool's input and
// result (a Write of a large file, a big MCP result), and a cut-off input
// would leave "needs approval" on screen until the turn ends. The hook is
// async, so the size never delays the agent.
const sessionStateStdinLimit = 64 << 20

// hookNow is the clock the state hooks stamp an event with. A var for tests.
var hookNow = time.Now

var workbenchSessionStateCmd = &cobra.Command{
	Use:   "session-state",
	Short: "Record what an embedded terminal's Claude Code session is doing (a Claude Code hook)",
	Long: "The UserPromptSubmit, Notification, PostToolUse, StopFailure, SubagentStop and\n" +
		"SubagentStart hook installed by `integrate claude-code --workbench N`: it reads the hook\n" +
		"input on stdin and stores working / waiting / approval, records subagent and teammate\n" +
		"turns, and lowers the Stop's count of background agents, on the Desktop terminal's row\n" +
		"named by WATCHTOWER_TERMINAL_SESSION_ID, so the Workbench\n" +
		"shows it. Without that variable it does nothing. It never prints to stdout and always\n" +
		"exits 0.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench check` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		agent, err := hookAgentFor(cmd, workbenchSessionStateFlagAgent)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: session state not recorded: %v\n", err)
			return nil
		}
		if agent == agentkind.Codex {
			runCodexSessionStateHook(cmd.InOrStdin(), cmd.ErrOrStderr())
			return nil
		}
		if err := checkWorkbenchIDFlags(cmd); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: session state not recorded: %v\n", err)
			return nil
		}
		runSessionStateHook(cmd.InOrStdin(), cmd.ErrOrStderr(), workbenchSessionStateFlagWorkbench)
		return nil
	},
}

var workbenchSessionStateFlagWorkbench, workbenchSessionStateFlagAgent string

func init() {
	addWorkbenchIDFlag(workbenchSessionStateCmd, &workbenchSessionStateFlagWorkbench, "workbench id")
	addHookAgentFlag(workbenchSessionStateCmd, &workbenchSessionStateFlagAgent)
	workbenchCmd.AddCommand(workbenchSessionStateCmd)
}

// agentErrorRunes caps the StopFailure error type a row stores.
const agentErrorRunes = 60

// hookCwdMaxBytes caps a working directory the hooks record.
const hookCwdMaxBytes = 4096

// hookCwd is the working directory a hook event records on the row (board
// #566), or "" for none: only the main agent's events record one — never an
// event with agentID (a subagent's or teammate's) nor a SubagentStart or
// SubagentStop — and only an absolute path of at most 4096 bytes with no NUL
// or newline, cleaned.
func hookCwd(event, agentID, cwd string) string {
	if agentID != "" || event == "SubagentStart" || event == "SubagentStop" {
		return ""
	}
	return hookPath(cwd)
}

// hookPath is a hook input's cwd cleaned, or "" when it is not an absolute
// path of at most hookCwdMaxBytes bytes free of NUL and newlines. The cwd
// column (hookCwd) and the session's worktree ledger share it.
func hookPath(cwd string) string {
	if !filepath.IsAbs(cwd) || len(cwd) > hookCwdMaxBytes || strings.ContainsAny(cwd, "\x00\n\r") {
		return ""
	}
	return filepath.Clean(cwd)
}

// agentFailure is the failure a StopFailure records: its error type on one
// line, clipped, or ” when the field is missing or not a string. nil for
// every other event.
func (in hookEvent) agentFailure() *db.AgentFailure {
	if in.Event != "StopFailure" {
		return nil
	}
	var e string
	if json.Unmarshal(in.Error, &e) != nil {
		e = ""
	}
	return &db.AgentFailure{Error: briefClip(asks.OneLine(e), agentErrorRunes)}
}

// agentStateFor maps a hook event to the state it records. onlyFrom is the
// stored state the write requires; agentStateFor always returns "" for it,
// and recordHookAgentState sets it to approval for a subagent's PostToolUse.
// A main-thread PostToolUse means a tool just ran: it clears "needs
// approval" after a granted permission and "waiting" when a turn started
// without a prompt (a teammate or background-task message, a wakeup fires
// no UserPromptSubmit); one stamped before the stop's "waiting", or whose
// tool call the transcript places before the stop, writes nothing. A
// SubagentStart or SubagentStop records no state (ok true, state ""):
// recordHookAgentState routes it to the agent turns and the background count
// (boards #411, #543). A Codex PermissionRequest is Claude Code's
// permission_prompt notification (spec 2026-10-12 §6.3). ok is false for an
// event that records nothing — an unknown event or notification type, or a
// missing one.
func agentStateFor(event, notificationType string) (state, onlyFrom string, ok bool) {
	switch event {
	case "UserPromptSubmit":
		return agentStateWorking, "", true
	case "PermissionRequest":
		return agentStateApproval, "", true
	case "Stop", "StopFailure":
		return agentStateWaiting, "", true
	case "PostToolUse":
		return agentStateWorking, "", true
	case "SubagentStart", "SubagentStop":
		return "", "", true
	case "Notification":
		switch notificationType {
		case "permission_prompt", "elicitation_dialog":
			return agentStateApproval, "", true
		case "idle_prompt":
			return agentStateWaiting, "", true
		}
	}
	return "", "", false
}

// runSessionStateHook is `workbench session-state`. A UserPromptSubmit
// hook's stdout becomes the agent's context and its exit 2 blocks the
// prompt, so nothing here writes stdout, every path returns (the caller
// exits 0), a panic is recovered, and a real failure is one stderr line.
// Without the terminal env var the session is not a Desktop row: stdin is
// not even read.
func runSessionStateHook(stdin io.Reader, stderr io.Writer, rawWorkbenchID string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: session state not recorded: panic: %v\n", r)
		}
	}()
	rowID, ok, err := terminalSessionRowID()
	if !ok {
		return
	}
	if err == nil {
		err = recordHookAgentState(stdin, stderr, rowID, rawWorkbenchID)
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: session state not recorded: %v\n", err)
	}
}

// recordHookAgentState records the event's state, then — whatever the state
// write did — the session's worktree ledger (recordSessionLedger), which
// reports its own failure on stderr and never changes the returned error.
func recordHookAgentState(stdin io.Reader, stderr io.Writer, rowID int64, rawWorkbenchID string) error {
	workbenchID, err := strconv.ParseInt(strings.TrimSpace(rawWorkbenchID), 10, 64)
	if err != nil || workbenchID <= 0 {
		return fmt.Errorf("invalid --workbench %q", briefClip(rawWorkbenchID, 40))
	}
	// The event time is when the hook started, not when a large input
	// finished reading: a slow read must not outrank a later event.
	at := hookNow()
	ctx, cancel := context.WithTimeout(context.Background(), sessionStateInputWait)
	in, err := readHookEvent(ctx, stdin, sessionStateStdinLimit, agentkind.Claude)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	state, onlyFrom, ok := agentStateFor(in.Event, in.NotificationType)
	if !ok || in.SessionID == "" || (in.agentTurnEvent() && !in.recordsAgentTurn()) {
		return nil
	}
	turn, subagentToolRun := in.toolRunTurn()
	turn.cwd = hookCwd(in.Event, in.AgentID, in.Cwd)
	// Not under a deadline: db.Open may be applying a migration, which must
	// never be cut off part-way (the Stop hook precedent); the hook is async,
	// so Claude Code never waits for it.
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	switch {
	case in.agentTurnEvent():
		err = recordAgentTurn(database, rowID, workbenchID, in, at, agentkind.Claude)
	case subagentToolRun:
		err = recordSubagentToolRun(database, rowID, workbenchID, in.SessionID, state, at)
	default:
		err = recordAgentState(database, rowID, workbenchID, in.SessionID, state, onlyFrom, in.agentFailure(),
			in.Event == "UserPromptSubmit", at, turn)
	}
	recordSessionLedger(database, stderr, rowID, workbenchID, in.SessionID, in.Cwd, at)
	return err
}

// recordSubagentToolRun records a subagent's tool result: a background
// subagent works on after the main turn stopped to wait for the owner, so
// its tool results clear only a granted permission, and over the Stop's
// count they are a heartbeat. At most
// one of the two writes lands: one needs approval, the other waiting.
func recordSubagentToolRun(database *db.DB, rowID, workbenchID int64, sessionID, state string, at time.Time) error {
	if err := recordAgentState(database, rowID, workbenchID, sessionID, state, agentStateApproval, nil, false, at, hookTurn{}); err != nil {
		return err
	}
	return recordBackgroundReport(database, rowID, workbenchID, sessionID, at, nil)
}

// codexStateEvents are the Codex events `session-state --agent codex`
// records (spec 2026-10-12 §6.3). Codex has no Notification or StopFailure,
// so a payload naming one records nothing (a codex row never gets
// agent_failed_at), and its Stop is the drift check's.
var codexStateEvents = map[string]bool{
	"UserPromptSubmit": true, "PermissionRequest": true, "PostToolUse": true,
	"SubagentStart": true, "SubagentStop": true,
}

// runCodexSessionStateHook is `workbench session-state --agent codex`: the
// Claude Code hook's contract (nothing on stdout, exit 0, a real failure is
// one stderr line) on the Codex row the hook runs in.
func runCodexSessionStateHook(stdin io.Reader, stderr io.Writer) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: session state not recorded: panic: %v\n", r)
		}
	}()
	at := hookNow()
	row, in, ok := readCodexHook(stdin, stderr, "session state not recorded", sessionStateInputWait,
		sessionStateStdinLimit, openHookDB)
	if !ok {
		return
	}
	if codexStateEvents[in.Event] {
		noteForeignCodexSession(stderr, row, in.SessionID, in.Event)
	}
	if err := recordCodexHookState(stderr, row, in, at); err != nil {
		fmt.Fprintf(stderr, "watchtower: session state not recorded: %v\n", err)
	}
}

// recordCodexHookState records a Codex state event of row's session (spec
// §6.3) the way the Claude Code hook does, with two differences: the
// subagent turns count the background agents themselves (Codex sends no
// background_tasks), and a main-thread tool result is ordered by time only —
// Codex runs its state hooks synchronously, so no hook outlives its turn and
// the transcript turn order is not needed. An event of another session (a
// foreign id, or a row with no id yet: spec I6) writes nothing. After the
// state write comes the session's worktree ledger, as for Claude Code.
func recordCodexHookState(stderr io.Writer, row db.TerminalSession, in hookEvent, at time.Time) error {
	if !codexStateEvents[in.Event] || in.SessionID == "" || in.SessionID != row.ClaudeSessionID.String ||
		(in.agentTurnEvent() && in.AgentID == "") {
		return nil
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	rowID, workbenchID := row.ID, row.WorkbenchID.Int64
	state, _, _ := agentStateFor(in.Event, "")
	turn, subagentToolRun := in.toolRunTurn()
	turn.cwd = hookCwd(in.Event, in.AgentID, in.Cwd)
	turn.transcriptPath = ""
	switch {
	case in.agentTurnEvent():
		err = recordAgentTurn(database, rowID, workbenchID, in, at, agentkind.Codex)
	case subagentToolRun:
		err = recordSubagentToolRun(database, rowID, workbenchID, in.SessionID, state, at)
	default:
		err = recordAgentState(database, rowID, workbenchID, in.SessionID, state, "", nil,
			in.Event == "UserPromptSubmit", at, turn)
	}
	recordSessionLedger(database, stderr, rowID, workbenchID, in.SessionID, in.Cwd, at)
	return err
}

// agentTurnEvent says the event starts or ends a subagent's or teammate's
// turn (board #543).
func (in hookEvent) agentTurnEvent() bool {
	return in.Event == "SubagentStart" || in.Event == "SubagentStop"
}

// recordsAgentTurn says a SubagentStart or SubagentStop names an agent the
// turns track: one with an agent_id and a type. Claude Code's internal agents
// (prompt suggestions, /btw) have no type and say nothing about the work.
func (in hookEvent) recordsAgentTurn() bool {
	return in.AgentID != "" && in.AgentType != ""
}

// recordAgentTurn records a SubagentStart's or SubagentStop's turn on the
// row (board #543), whatever its state: a teammate works across the main
// agent's turns. A SubagentStop with a list then lowers the Stop's count to
// what that list and the recorded turns still count (board #411); it never
// raises or starts one. For agent Codex, which sends no list, the count is
// the turns still open (codexBackgroundCount).
func recordAgentTurn(database *db.DB, rowID, workbenchID int64, in hookEvent, at time.Time, agent agentkind.Kind) error {
	if !terminal.IsSessionID(in.SessionID) {
		return fmt.Errorf("the hook input carries no session id (%q)", briefClip(in.SessionID, 40))
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return fmt.Errorf("recording the agent turn: %w", err)
	}
	start := in.Event == "SubagentStart"
	turns, err := database.RecordTerminalAgentTurn(rowID, workbenchID, in.SessionID, in.AgentID, start,
		at.Truncate(time.Millisecond))
	// A replaced unreadable value is reported, never a reason to skip the
	// count: the turns returned are what the row now holds.
	replaced := errors.Is(err, db.ErrAgentTurnsUnreadable)
	if (err != nil && !replaced) || turns == nil || start {
		return err
	}
	remaining, ok := backgroundAgents(in.BackgroundTasks, turns, in.AgentID)
	if agent == agentkind.Codex {
		remaining, ok = codexBackgroundCount(turns), true
	}
	if !ok {
		return err
	}
	return errors.Join(err, recordBackgroundReport(database, rowID, workbenchID, in.SessionID, at, &remaining))
}

// toolRunTurn classifies a PostToolUse: subagent is true for one fired
// inside a subagent, and a main-thread one gets its turn placement. The zero
// values are every other event.
func (in hookEvent) toolRunTurn() (turn hookTurn, subagent bool) {
	if in.Event != "PostToolUse" {
		return hookTurn{}, false
	}
	if in.AgentID != "" {
		return hookTurn{}, true
	}
	return hookTurn{toolRun: true, transcriptPath: in.TranscriptPath, toolUseID: in.ToolUseID}, false
}

// hookTurn ties a main-thread PostToolUse or the Stop hook's write to its
// turn (board #368): the async PostToolUse's process can start after the
// sync Stop hook's, so the hook start times alone would let an ended turn's
// tool result turn the stop's "waiting" back into "working". The zero value
// is every other event.
type hookTurn struct {
	toolRun                   bool // a main-thread PostToolUse
	stop                      bool // the sync Stop hook
	transcriptPath, toolUseID string
	// tasks is the Stop's background_tasks: recordAgentState counts it into
	// background against the row's agent turns (boards #411, #543).
	tasks backgroundTasks
	// background is the Stop's count of background agents at work; invalid
	// for none or unknown, never zero.
	background sql.NullInt64
	// cwd is the main agent's working directory the event reports (hookCwd,
	// board #566); "" = none. It rides in the state write, or is written
	// alone when the state write is a repeat or held back.
	cwd string
}

// terminalSessionRowID is the terminal_sessions row the Desktop launched
// this claude in; ok is false without the env var (an external terminal, v1
// tracks none of them).
func terminalSessionRowID() (id int64, ok bool, err error) {
	raw, ok := os.LookupEnv(terminalSessionEnv)
	if !ok {
		return 0, false, nil
	}
	id, err = strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || id <= 0 {
		return 0, true, fmt.Errorf("invalid %s %q", terminalSessionEnv, briefClip(raw, 40))
	}
	return id, true, nil
}

// recordAgentState stores state on workbench workbenchID's claude row rowID
// when the hook came from the conversation the row runs: a nested
// `claude -p` the agent starts inherits the env var but has its own session
// id, and must not move the row. Read first, so the common no-change case
// (every PostToolUse of a working turn) never waits for the write lock; the
// write repeats every guard, so a race with another hook stays correct.
// failure is a StopFailure's error, nil for every other event; prompt says
// the event is a UserPromptSubmit. nil when a guard holds the write back — a
// gone row is not an error. turn orders a main-thread tool result and the
// Stop by the transcript: a tool call from before the run's last Stop writes
// nothing, and the Stop replaces a tool result's `working` stamped after it
// (its process started later); a call the transcript cannot place falls back
// to the time order. A Stop's background count that differs from the
// stored one makes its `waiting` a change; one repeating the stored count
// only refreshes agent_background_at (a fresh report, not a transition).
// A prompt clears a chat question asked before it (the owner answered or
// moved on in the terminal), whatever its state write does; so does a
// main-thread tool result whose `working` ends a `waiting` (the agent went
// on by itself). Nothing else touches the question (PROJ-11, spec
// 2026-10-10-owner-asks-v2 Part 4.7).
func recordAgentState(database *db.DB, rowID, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	at = at.Truncate(time.Millisecond) // the stored precision
	if turn.stop {
		turns, err := database.TerminalAgentTurns(row.ID)
		if err != nil {
			return err
		}
		if n, ok := backgroundAgents(turn.tasks, turns, ""); ok && n > 0 {
			turn.background = sql.NullInt64{Int64: n, Valid: true}
		}
	}
	var clearErr error
	if prompt {
		clearErr = clearChatQuestion(database, row, workbenchID, sessionID, at)
	}
	return errors.Join(clearErr, recordAgentStateOver(database, row, workbenchID, sessionID, state, onlyFrom, failure, prompt, at, turn))
}

// recordAgentStateOver is recordAgentState's decision over the row it read:
// a repeat (at most a background report), a write the guards hold back, or
// writeAgentState. A failed prompt clear never skips it.
func recordAgentStateOver(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	rowID := row.ID
	switch {
	case repeatsAgentState(row, state, failure, prompt, turn.background):
		var reportErr error
		if turn.stop && turn.background.Valid {
			reportErr = writeBackgroundReport(database, rowID, workbenchID, sessionID, at, nil)
		}
		return errors.Join(reportErr, recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at))
	case onlyFrom != "" && row.AgentState.String != onlyFrom,
		!row.AgentStateAt.IsZero() && !at.After(row.AgentStateAt) && !stopEndsToolRun(row, turn):
		return recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at)
	}
	return writeAgentState(database, row, workbenchID, sessionID, state, onlyFrom, failure, prompt, at, turn)
}

// writeAgentState is recordAgentState's write over the row it read: the
// turn order's last check, then the guarded UPDATE, then the chat question's
// clear when a main-thread tool result ended a `waiting`.
func writeAgentState(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	order := db.AgentOrder{Stop: turn.stop, Background: turn.background, Cwd: turn.cwd}
	if turn.toolRun {
		order.ToolRun, order.SeenTurnEnd = true, row.TurnEnd
		if row.TurnEnd.Valid && toolCallTurn(turn.transcriptPath, turn.toolUseID, row.TurnEnd.Int64) == toolCallBeforeStop {
			// The ended turn's tool result: no state, but its cwd is the
			// agent's.
			return recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at)
		}
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	written, err := database.SetTerminalAgentState(row.ID, workbenchID, sessionID, state, at, onlyFrom, failure, prompt, order)
	if err == nil && !written {
		// A guard held the write back after the read (a racing hook): the
		// cwd still goes, under its own guards.
		return recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at)
	}
	if err != nil || !turn.toolRun || row.AgentState.String != agentStateWaiting {
		return err
	}
	return clearChatQuestion(database, row, workbenchID, sessionID, at)
}

// recordCwdAlone records cwd on row rowID when no state write carries it
// (board #566): only when it differs from the row's, is reported after the
// row's and not before the run mark (AgentCwd.WouldRecord; read first, so
// the common case — the same folder — never waits for the write lock);
// SetTerminalAgentCwd repeats the guards. "" writes nothing.
func recordCwdAlone(database *db.DB, rowID, workbenchID int64, sessionID, cwd string, at time.Time) error {
	if cwd == "" {
		return nil
	}
	stored, err := database.TerminalAgentCwd(rowID)
	if err != nil || !stored.WouldRecord(cwd, at) {
		return err
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err = setTerminalAgentCwd(database, rowID, workbenchID, sessionID, cwd, at)
	return err
}

// setTerminalAgentCwd is the cwd's write alone; a seam for tests.
var setTerminalAgentCwd = (*db.DB).SetTerminalAgentCwd

// clearChatQuestion drops row's chat question when one is stored: the read
// row says so first, so the common case (no question) never waits for the
// write lock; ClearChatQuestionBefore keeps a question asked at or after at.
func clearChatQuestion(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID string, at time.Time) error {
	if row.ChatQuestionAt == "" {
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	return database.ClearChatQuestionBefore(row.ID, workbenchID, sessionID, at)
}

// stopEndsToolRun: the Stop replaces a main-thread tool result's `working`
// whatever its time — no main-thread tool of a later turn runs before the
// sync Stop hook returns, so that tool ran in the ending turn.
func stopEndsToolRun(row *db.TerminalSession, turn hookTurn) bool {
	return turn.stop && row.ToolRun && row.AgentState.String == agentStateWorking
}

// hookSessionRow reads workbench workbenchID's agent row rowID (claude or
// codex) when the hook came from the conversation the row runs: a nested
// `claude -p` the agent starts inherits the env var but has its own session
// id, and must not move the row. nil, nil when the row is gone (deleted while
// its terminal ran) or belongs to another workbench, kind or conversation;
// a codex row with no id yet matches no conversation (spec I6).
func hookSessionRow(database *db.DB, rowID, workbenchID int64, sessionID string) (*db.TerminalSession, error) {
	if !terminal.IsSessionID(sessionID) {
		return nil, fmt.Errorf("the hook input carries no session id (%q)", briefClip(sessionID, 40))
	}
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if row.WorkbenchID.Int64 != workbenchID || !agentkind.IsAgent(row.Kind) || row.ClaudeSessionID.String != sessionID {
		return nil, nil
	}
	return row, nil
}

// recordBackgroundReport records a later report about the Stop's background
// subagents (board #411) on the row: a subagent's tool result (count nil, a
// heartbeat) or a SubagentStop (count = the subagents its snapshot still
// lists). Read first with recordAgentState's row guards, so the common case
// — no count, or another state — never waits for the write lock; it writes
// only over a `waiting` with a positive count reported before at, and
// LowerTerminalBackground repeats every guard.
func recordBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count *int64) error {
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	at = at.Truncate(time.Millisecond) // the stored precision
	if row.AgentState.String != agentStateWaiting || row.Background.Int64 <= 0 ||
		(!row.BackgroundAt.IsZero() && !at.After(row.BackgroundAt)) {
		return nil
	}
	return writeBackgroundReport(database, rowID, workbenchID, sessionID, at, count)
}

// writeBackgroundReport stamps agent_background_at with at and, with count,
// lowers agent_background to it: a background report, never a transition.
func writeBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count *int64) error {
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err := database.LowerTerminalBackground(rowID, workbenchID, sessionID, at, count)
	return err
}

// repeatsAgentState says the write would change nothing the guarded UPDATE
// lets through: a StopFailure with another error type is a change, and so is
// a prompt's `working` on a finished row (it clears finished_at; a tool
// run's `working` over `working` never does), and a `waiting` whose stored
// background count differs from background, the count the write stores
// (invalid for every `waiting` but a Stop that counted some).
func repeatsAgentState(row *db.TerminalSession, state string, failure *db.AgentFailure, prompt bool,
	background sql.NullInt64) bool {
	switch {
	case row.AgentState.String != state:
		return false
	case state == agentStateWaiting && row.Background != background:
		return false
	case failure != nil:
		return row.AgentFailure != nil && row.AgentFailure.Error == failure.Error
	default:
		return state != "working" || !row.Finished || !prompt
	}
}
