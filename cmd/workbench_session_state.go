package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

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
	Long: "The UserPromptSubmit, Notification, PostToolUse, StopFailure and SubagentStop hook\n" +
		"installed by `integrate claude-code --workbench N`: it reads the hook input on stdin and\n" +
		"stores working / waiting / approval, and lowers the Stop's count of background subagents,\n" +
		"on the Desktop terminal's row named by WATCHTOWER_TERMINAL_SESSION_ID, so the Workbench\n" +
		"shows it. Without that variable it does nothing. It never prints to stdout and always\n" +
		"exits 0.",
	// No root schema/config pre-run: a broken config must not fail the hook
	// (the `workbench check` precedent); the DB is opened by the command.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := checkWorkbenchIDFlags(cmd); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: session state not recorded: %v\n", err)
			return nil
		}
		runSessionStateHook(cmd.InOrStdin(), cmd.ErrOrStderr(), workbenchSessionStateFlagWorkbench)
		return nil
	},
}

var workbenchSessionStateFlagWorkbench string

func init() {
	addWorkbenchIDFlag(workbenchSessionStateCmd, &workbenchSessionStateFlagWorkbench, "workbench id")
	workbenchCmd.AddCommand(workbenchSessionStateCmd)
}

// agentErrorRunes caps the StopFailure error type a row stores.
const agentErrorRunes = 60

// sessionStateInput is the part of Claude Code's hook input the state hook
// reads; every other field is ignored.
type sessionStateInput struct {
	HookEventName    string `json:"hook_event_name"`
	SessionID        string `json:"session_id"`
	NotificationType string `json:"notification_type"`
	// AgentID is set when the hook fired inside a subagent; AgentType is
	// its type, empty for Claude Code's internal agents (board #411).
	AgentID   string `json:"agent_id"`
	AgentType string `json:"agent_type"`
	// BackgroundTasks is a SubagentStop's snapshot of in-flight background
	// tasks (board #411). A Stop's is never read here: only the sync Stop
	// hook records a count.
	BackgroundTasks backgroundTasks `json:"background_tasks"`
	// TranscriptPath and a PostToolUse's ToolUseID place the tool call
	// against the last Stop (board #368).
	TranscriptPath string `json:"transcript_path"`
	ToolUseID      string `json:"tool_use_id"`
	// Error is a StopFailure's error type ("rate_limit", pinned by
	// testdata/stopfailure_rate_limit.json). Raw, so a non-string value
	// never fails the whole input.
	Error json.RawMessage `json:"error"`
}

// agentFailure is the failure a StopFailure records: its error type on one
// line, clipped, or ” when the field is missing or not a string. nil for
// every other event.
func (in sessionStateInput) agentFailure() *db.AgentFailure {
	if in.HookEventName != "StopFailure" {
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
// SubagentStop records no state (ok true, state ""): recordHookAgentState
// routes it to the background count (board #411). ok is false for an event
// that records nothing — an unknown event or notification type, or a
// missing one.
func agentStateFor(event, notificationType string) (state, onlyFrom string, ok bool) {
	switch event {
	case "UserPromptSubmit":
		return agentStateWorking, "", true
	case "Stop", "StopFailure":
		return agentStateWaiting, "", true
	case "PostToolUse":
		return agentStateWorking, "", true
	case "SubagentStop":
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
		err = recordHookAgentState(stdin, rowID, rawWorkbenchID)
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: session state not recorded: %v\n", err)
	}
}

func recordHookAgentState(stdin io.Reader, rowID int64, rawWorkbenchID string) error {
	workbenchID, err := strconv.ParseInt(strings.TrimSpace(rawWorkbenchID), 10, 64)
	if err != nil || workbenchID <= 0 {
		return fmt.Errorf("invalid --workbench %q", briefClip(rawWorkbenchID, 40))
	}
	// The event time is when the hook started, not when a large input
	// finished reading: a slow read must not outrank a later event.
	at := hookNow()
	ctx, cancel := context.WithTimeout(context.Background(), sessionStateInputWait)
	in, err := readHookInputLimit[sessionStateInput](ctx, stdin, sessionStateStdinLimit)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	state, onlyFrom, ok := agentStateFor(in.HookEventName, in.NotificationType)
	if !ok || in.SessionID == "" {
		return nil
	}
	var remaining int64
	if in.HookEventName == "SubagentStop" {
		if remaining, ok = in.subagentStopRemaining(); !ok {
			return nil
		}
	}
	turn, subagentToolRun := in.toolRunTurn()
	if subagentToolRun {
		// A background subagent works on after the main turn stopped to
		// wait for the owner: its tool results clear only a granted
		// permission; over the Stop's count they are a heartbeat.
		onlyFrom = agentStateApproval
	}
	// Not under a deadline: db.Open may be applying a migration, which must
	// never be cut off part-way (the Stop hook precedent); the hook is async,
	// so Claude Code never waits for it.
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	switch {
	case in.HookEventName == "SubagentStop":
		return recordBackgroundReport(database, rowID, workbenchID, in.SessionID, at, &remaining)
	case subagentToolRun:
		// At most one of the two writes: one needs approval, the other waiting.
		if err := recordAgentState(database, rowID, workbenchID, in.SessionID, state, onlyFrom, nil, false, at, turn); err != nil {
			return err
		}
		return recordBackgroundReport(database, rowID, workbenchID, in.SessionID, at, nil)
	}
	return recordAgentState(database, rowID, workbenchID, in.SessionID, state, onlyFrom, in.agentFailure(),
		in.HookEventName == "UserPromptSubmit", at, turn)
}

// subagentStopRemaining is the count a SubagentStop lowers the Stop's to:
// the subagents its snapshot lists besides the stopping one. ok is false for
// an internal agent's (no agent_type) or one without a list: it says
// nothing about them.
func (in sessionStateInput) subagentStopRemaining() (remaining int64, ok bool) {
	remaining, ok = backgroundSubagents(in.BackgroundTasks, in.AgentID)
	return remaining, ok && in.AgentType != ""
}

// toolRunTurn classifies a PostToolUse: subagent is true for one fired
// inside a subagent, and a main-thread one gets its turn placement. The zero
// values are every other event.
func (in sessionStateInput) toolRunTurn() (turn hookTurn, subagent bool) {
	if in.HookEventName != "PostToolUse" {
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
	// background is the Stop's count of in-flight background subagents
	// (board #411); invalid for none or unknown, never zero.
	background sql.NullInt64
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
func recordAgentState(database *db.DB, rowID, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	at = at.Truncate(time.Millisecond) // the stored precision
	switch {
	case repeatsAgentState(row, state, failure, prompt, turn.background):
		if turn.stop && turn.background.Valid {
			return writeBackgroundReport(database, rowID, workbenchID, sessionID, at, nil)
		}
		return nil
	case onlyFrom != "" && row.AgentState.String != onlyFrom,
		!row.AgentStateAt.IsZero() && !at.After(row.AgentStateAt) && !stopEndsToolRun(row, turn):
		return nil
	}
	order := db.AgentOrder{Stop: turn.stop, Background: turn.background}
	if turn.toolRun {
		order.ToolRun, order.SeenTurnEnd = true, row.TurnEnd
		if row.TurnEnd.Valid && toolCallTurn(turn.transcriptPath, turn.toolUseID, row.TurnEnd.Int64) == toolCallBeforeStop {
			return nil // the ended turn's tool result
		}
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err = database.SetTerminalAgentState(rowID, workbenchID, sessionID, state, at, onlyFrom, failure, prompt, order)
	return err
}

// stopEndsToolRun: the Stop replaces a main-thread tool result's `working`
// whatever its time — no main-thread tool of a later turn runs before the
// sync Stop hook returns, so that tool ran in the ending turn.
func stopEndsToolRun(row *db.TerminalSession, turn hookTurn) bool {
	return turn.stop && row.ToolRun && row.AgentState.String == agentStateWorking
}

// hookSessionRow reads workbench workbenchID's claude row rowID when the
// hook came from the conversation the row runs: a nested `claude -p` the
// agent starts inherits the env var but has its own session id, and must
// not move the row. nil, nil when the row is gone (deleted while its
// terminal ran) or belongs to another workbench, kind or conversation.
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
	if row.WorkbenchID.Int64 != workbenchID || row.Kind != "claude" || row.ClaudeSessionID.String != sessionID {
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
