package cmd

import (
	"context"
	"database/sql"
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
	"watchtower/internal/sessionagent"
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
	Long: "The UserPromptSubmit, Notification, PreToolUse, PostToolUse, PostToolUseFailure,\n" +
		"StopFailure, SubagentStop and SubagentStart hook installed by\n" +
		"`integrate claude-code --workbench N`: it reads the hook\n" +
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
		if launchHooks(agent) {
			runCodexSessionStateHook(cmd.InOrStdin(), cmd.ErrOrStderr())
			return nil
		}
		runSessionStateHook(cmd.InOrStdin(), cmd.ErrOrStderr(), workbenchSessionStateFlagWorkbench)
		return nil
	},
}

var workbenchSessionStateFlagWorkbench, workbenchSessionStateFlagAgent string

func init() {
	workbenchSessionStateCmd.Flags().StringVar(&workbenchSessionStateFlagWorkbench, workbenchFlag, "", "workbench id")
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

// agentFailure is the failure a StopFailure (a hook's, or a pulled turn's)
// records: its error type on one line, clipped, or "" when the field is
// missing or not a string. nil for every other event.
func agentFailure(in hookEvent) *db.AgentFailure {
	e, ok := in.FailureText()
	if !ok {
		return nil
	}
	return &db.AgentFailure{Error: briefClip(asks.OneLine(e), agentErrorRunes)}
}

// agentStateFor maps a hook event to the state it records, with no stored
// state required (recordSubagentToolRun requires approval for a subagent's
// PostToolUse itself). A main-thread PostToolUse means a tool just ran: it
// clears "needs approval" after a granted permission and "waiting" when a
// turn started without a prompt (a teammate or background-task message, a
// wakeup fires no UserPromptSubmit); one stamped before the stop's "waiting", or whose
// tool call the transcript places before the stop, writes nothing. A
// PostToolUseFailure (a tool ran and failed) is a PostToolUse, unless the
// owner interrupted the tool (is_interrupt): recordHookAgentState then
// records `waiting` for a main-thread one and nothing for a subagent's. A main-thread
// PreToolUse (a tool starts) is the same signal under the same turn order,
// but never over "needs approval" (board #988, ask #525:
// hookTurn.notOverApproval). A
// SubagentStart or SubagentStop records no state (ok true, state ""):
// recordHookAgentState routes it to the agent turns and the background count
// (boards #411, #543). A Codex PermissionRequest is Claude Code's
// permission_prompt notification (spec 2026-10-12 §6.3). ok is false for an
// event that records nothing — an unknown event or notification type, or a
// missing one.
func agentStateFor(event, notificationType string) (state string, ok bool) {
	switch event {
	case "UserPromptSubmit":
		return agentStateWorking, true
	case "PermissionRequest":
		return agentStateApproval, true
	case "Stop", "StopFailure":
		return agentStateWaiting, true
	case "PreToolUse", "PostToolUse", "PostToolUseFailure":
		return agentStateWorking, true
	case "SubagentStart", "SubagentStop":
		return "", true
	case "Notification":
		switch notificationType {
		case "permission_prompt", "elicitation_dialog":
			return agentStateApproval, true
		case "idle_prompt":
			return agentStateWaiting, true
		}
	}
	return "", false
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
	reportStateHookError(stderr, err)
}

// chatQuestionNotCleared is a failed clear of the chat question: the state
// write it follows may have landed, so it is reported apart.
type chatQuestionNotCleared struct{ err error }

func (e chatQuestionNotCleared) Error() string { return "chat question not cleared: " + e.err.Error() }
func (e chatQuestionNotCleared) Unwrap() error { return e.err }

// agentCwdNotRecorded is a failed write (or read) of the agent's cwd alone
// (recordCwdAlone): the state itself was a repeat or held back, so it is
// reported apart.
type agentCwdNotRecorded struct{ err error }

func (e agentCwdNotRecorded) Error() string { return "agent cwd not recorded: " + e.err.Error() }
func (e agentCwdNotRecorded) Unwrap() error { return e.err }

// reportStateHookError prints a state hook's failure, one line per failure
// it joins at any depth: a failed clear of the chat question and a failed
// cwd write under their own prefixes, every other one as "session state not
// recorded".
func reportStateHookError(stderr io.Writer, err error) {
	for _, e := range joinedErrors(err) {
		var notCleared chatQuestionNotCleared
		var cwd agentCwdNotRecorded
		var turnEnd turnEndNotMoved
		switch {
		case errors.As(e, &turnEnd):
			fmt.Fprintf(stderr, "watchtower: %v\n", turnEnd)
		case errors.As(e, &notCleared):
			fmt.Fprintf(stderr, "watchtower: %v\n", notCleared)
		case errors.As(e, &cwd):
			fmt.Fprintf(stderr, "watchtower: %v\n", cwd)
		default:
			fmt.Fprintf(stderr, "watchtower: session state not recorded: %v\n", e)
		}
	}
}

// joinedErrors is err's errors.Join leaves, nested joins flattened; none
// for nil.
func joinedErrors(err error) []error {
	if err == nil {
		return nil
	}
	joined, ok := err.(interface{ Unwrap() []error })
	if !ok {
		return []error{err}
	}
	var out []error
	for _, e := range joined.Unwrap() {
		out = append(out, joinedErrors(e)...)
	}
	return out
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
	// finished reading: a slow read must not outrank a later event. The lock
	// budget starts there too, so the input wait counts against it.
	at, deadline := hookNow(), lockNow().Add(stateHookBudget)
	ctx, cancel := context.WithTimeout(context.Background(), sessionStateInputWait)
	in, err := readHookEvent(ctx, stdin, sessionStateStdinLimit, agentkind.Claude)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	state, ok := agentStateFor(in.Event, in.NotificationType)
	if !ok || in.SessionID == "" || (in.AgentTurnEvent() && !in.RecordsAgentTurn()) || in.SubagentToolStart() ||
		(in.InterruptedTool() && in.AgentID != "") {
		return nil
	}
	if in.InterruptedTool() {
		state = agentStateWaiting
	}
	turn, subagentToolRun := toolRunTurnOf(in)
	turn.cwd = hookCwd(in.Event, in.AgentID, in.Cwd)
	turn.lock = stateHookLockWait.until(deadline)
	// Not under a deadline: db.Open may be applying a migration, which must
	// never be cut off part-way (the Stop hook precedent); the hook is async,
	// so Claude Code never waits for it.
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	switch {
	case in.AgentTurnEvent():
		err = recordAgentTurn(database, rowID, workbenchID, in, at, agentkind.Claude, turn.lock)
	case subagentToolRun:
		err = recordSubagentToolRun(database, rowID, workbenchID, in, state, at, turn.lock)
	default:
		err = recordAgentEvent(database, rowID, workbenchID, in, agentStateWrite{state: state, at: at, turn: turn})
	}
	recordSessionLedger(database, stderr, rowID, workbenchID, in.SessionID, in.Cwd, at, turn.lock)
	return err
}

// recordSubagentToolRun records a subagent's tool result: a background
// subagent works on after the main turn stopped to wait for the owner, so
// its tool results clear only a granted permission, and over the Stop's
// count they are a heartbeat. At most
// one of the two writes lands: one needs approval, the other waiting.
func recordSubagentToolRun(database *db.DB, rowID, workbenchID int64, in hookEvent, state string, at time.Time,
	lock hookLockWait) error {
	if err := recordAgentEvent(database, rowID, workbenchID, in,
		agentStateWrite{state: state, onlyFrom: agentStateApproval, at: at, turn: hookTurn{lock: lock}}); err != nil {
		return err
	}
	return recordBackgroundReport(database, rowID, workbenchID, in.SessionID, at, nil, nil, lock)
}

// codexStateEvents are the Codex events `session-state --agent codex`
// records (spec 2026-10-12 §6.3). Codex has no Notification or StopFailure,
// so a payload naming one records nothing (a hook never sets a codex row's
// agent_failed_at: `workbench session-probe` reads a failed turn from the
// rollout, board #959), and its Stop is the drift check's. Interrupt (the
// owner's Esc) ends the turn as a Stop does, with no drift check.
var codexStateEvents = map[string]bool{
	"UserPromptSubmit": true, "PermissionRequest": true, "PostToolUse": true,
	"SubagentStart": true, "SubagentStop": true, "Interrupt": true,
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
	reportStateHookError(stderr, recordCodexHookState(stderr, row, in, at))
}

// recordCodexHookState records a Codex state event of row's session (spec
// §6.3) the way the Claude Code hook does, with two differences: the
// subagent turns count the background agents themselves (Codex sends no
// background_tasks), and a main-thread tool result is ordered by time only —
// Codex runs its state hooks synchronously, so no hook outlives its turn and
// the transcript turn order is not needed. An event of another session (a
// foreign id, or a row with no id yet: spec I6) writes nothing. After the
// state write comes the session's worktree ledger, as for Claude Code. Every
// event clears the row's watch issue (spec 2026-11-05 §3.5).
func recordCodexHookState(stderr io.Writer, row db.TerminalSession, in hookEvent, at time.Time) error {
	if !codexStateEvents[in.Event] || in.SessionID == "" || in.SessionID != row.ClaudeSessionID.String ||
		(in.AgentTurnEvent() && in.AgentID == "") {
		return nil
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	rowID, workbenchID := row.ID, row.WorkbenchID.Int64
	state, _ := agentStateFor(in.Event, "")
	turn, subagentToolRun := toolRunTurnOf(in)
	turn.cwd = hookCwd(in.Event, in.AgentID, in.Cwd)
	turn.transcriptPath = ""
	switch {
	case in.Event == "Interrupt":
		err = recordCodexStopState(database, row, in, at)
	case in.AgentTurnEvent():
		err = recordAgentTurn(database, rowID, workbenchID, in, at, agentkind.Codex, turn.lock)
	case subagentToolRun:
		err = recordSubagentToolRun(database, rowID, workbenchID, in, state, at, turn.lock)
	case in.Event == "UserPromptSubmit":
		err = recordCodexPrompt(database, rowID, workbenchID, in, at, turn)
	default:
		err = recordAgentEvent(database, rowID, workbenchID, in, agentStateWrite{state: state, at: at, turn: turn})
	}
	// Any hook event of the row's session says the agent is heard again: a
	// not-watched mark goes and the session host's watch re-arms (§3.5).
	if _, clearErr := database.ClearAgentWatchIssue(rowID); clearErr != nil {
		err = errors.Join(err, clearErr)
	}
	recordSessionLedger(database, stderr, rowID, workbenchID, in.SessionID, in.Cwd, at, turn.lock)
	return err
}

// recordCodexPrompt restamps a row that already reads working (a turn that
// failed with no Stop, board #959), then records the prompt's `working` as
// Claude Code's does. The session probe records a failure only when it is
// later than agent_state_at, so the failed turn's error never lands on this
// prompt's turn before its task_started reaches the rollout. The restamp goes
// first: a probe write landing before it turns the row to an older failed
// `waiting`, which the prompt's `working` then replaces (and clears); one
// landing after it is older than the new stamp and held back.
func recordCodexPrompt(database *db.DB, rowID, workbenchID int64, in hookEvent, at time.Time, turn hookTurn) error {
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	if _, err := database.RestampCodexPromptTurn(rowID, workbenchID, in.SessionID, at.Truncate(time.Millisecond)); err != nil {
		return err
	}
	return recordAgentEvent(database, rowID, workbenchID, in, agentStateWrite{state: agentStateWorking, at: at, turn: turn})
}

// recordAgentTurn records a SubagentStart's or SubagentStop's turn on the
// row (board #543), whatever its state: a teammate works across the main
// agent's turns. A SubagentStop with a list then lowers the Stop's count to
// what that list and the recorded turns still count (board #411); it never
// raises or starts one. For agent Codex, which sends no list, the count is
// the turns still open (codexBackgroundCount).
func recordAgentTurn(database *db.DB, rowID, workbenchID int64, in hookEvent, at time.Time, agent agentkind.Kind,
	lock hookLockWait) error {
	if !terminal.IsSessionID(in.SessionID) {
		return fmt.Errorf("the hook input carries no session id (%q)", briefClip(in.SessionID, 40))
	}
	start := in.Event == "SubagentStart"
	var turns db.AgentTurns
	err := lock.write(database, func() error {
		var err error
		turns, err = database.RecordTerminalAgentTurn(rowID, workbenchID, in.SessionID, in.AgentID, start,
			at.Truncate(time.Millisecond))
		return err
	})
	// A replaced unreadable value is reported, never a reason to skip the
	// count: the turns returned are what the row now holds.
	replaced := errors.Is(err, db.ErrAgentTurnsUnreadable)
	if (err != nil && !replaced) || turns == nil || start {
		return err
	}
	remaining, ok := backgroundAgents(in.BackgroundTasks, turns, in.AgentID)
	var shells *int64
	if ok {
		n := backgroundShells(in.BackgroundTasks)
		shells = &n
	}
	if !sessionagent.CapsOf(string(agent)).BackgroundTasks {
		remaining, ok, shells = codexBackgroundCount(turns), true, nil
	}
	if !ok {
		return err
	}
	return errors.Join(err, recordBackgroundReport(database, rowID, workbenchID, in.SessionID, at, &remaining, shells, lock))
}

// toolRunTurnOf classifies a tool event: subagent is true for one fired
// inside a subagent, and a main-thread one gets its turn placement — a
// PreToolUse never over "needs approval" (ask #525): the tool has not run.
// The zero values are every other event.
func toolRunTurnOf(in hookEvent) (turn hookTurn, subagent bool) {
	if !in.ToolEvent() {
		return hookTurn{}, false
	}
	if in.AgentID != "" {
		return hookTurn{}, true
	}
	if in.InterruptedTool() {
		return hookTurn{interrupt: true, transcriptPath: in.TranscriptPath, toolUseID: in.ToolUseID}, false
	}
	return hookTurn{toolRun: true, notOverApproval: in.Event == "PreToolUse",
		transcriptPath: in.TranscriptPath, toolUseID: in.ToolUseID}, false
}

// hookTurn ties a main-thread tool event (PreToolUse, PostToolUse,
// PostToolUseFailure) or the Stop hook's write to its turn (board #368):
// the async tool hook's process can start after the sync Stop hook's, so the
// hook start times alone would let an ended turn's tool event turn the
// stop's "waiting" back into "working". The zero value is every other event.
type hookTurn struct {
	toolRun bool // a main-thread tool event other than an interrupted one
	// notOverApproval holds a main-thread tool start back over "needs
	// approval" (board #988, ask #525): only a tool that ran — PostToolUse
	// or PostToolUseFailure — says the dialog was answered.
	notOverApproval bool
	stop            bool // the sync Stop hook
	// interrupt marks a main-thread tool the owner interrupted: its
	// `waiting` also ends the turn (board #1019, writeAgentState).
	interrupt                 bool
	transcriptPath, toolUseID string
	// tasks is the Stop's background_tasks: recordAgentState counts it into
	// background against the row's agent turns (boards #411, #543).
	tasks backgroundTasks
	// background is the Stop's count of background agents at work and
	// shells its count of background shells (board #1712): both invalid for
	// none or unknown, both valid (one may be zero) when either is above
	// zero.
	background, shells sql.NullInt64
	// cwd is the main agent's working directory the event reports (hookCwd,
	// board #566); "" = none. It rides in the state write, or is written
	// alone when the state write is a repeat or held back.
	cwd string
	// lock is how the event's writes wait for the write lock: the async
	// state hooks' stateHookLockWait, or the zero value (the Stop hook and
	// codex's synchronous hooks).
	lock hookLockWait
}

// stateHookLockWait is how the async Claude Code state hooks wait for the
// write lock (board #988, ask #525): up to 2 s, and once more after a busy
// lock, every write of one hook process inside one budget (until,
// stateHookBudget). A lost write used to leave "Stopped" on a working
// session until the next event.
var stateHookLockWait = hookLockWait{wait: 2 * time.Second, retry: true}

// stateHookBudget is how long after its start — before the input is read —
// one async state hook process may still begin a lock wait: the input wait,
// the database open and every lock wait come out of it, and the 0.5 s left
// of the hook's 5 s timeout covers the process start and the last write's
// own work. A write past it is not tried, so Claude Code never kills the
// hook part-way through its writes. (The SessionStart's id move takes the
// same budget from after its input: its hook has 10 s.)
const stateHookBudget = 4500 * time.Millisecond

// lockNow is the clock the lock budget reads; a var for tests.
var lockNow = time.Now

// errHookOutOfTime is a write the hook's lock budget left no time for.
var errHookOutOfTime = errors.New("no time left in the hook's lock budget")

// hookLockWait is how a hook write waits for the database's write lock. The
// zero value is one sessionRecordBusyTimeout wait with no retry and no
// budget: the Stop hook, the SessionStart's run mark and codex's synchronous
// hooks, which Claude Code (or codex) waits for.
type hookLockWait struct {
	wait     time.Duration
	retry    bool
	deadline time.Time // zero = no budget
}

// until is w with every write bounded by deadline.
func (w hookLockWait) until(deadline time.Time) hookLockWait {
	w.deadline = deadline
	return w
}

// attemptWait is the busy timeout of the next try: the wait, cut to what
// the budget has left; ok is false when under 1 ms is left — busy_timeout
// counts whole milliseconds, so such a try would not wait at all.
func (w hookLockWait) attemptWait() (wait time.Duration, ok bool) {
	wait = w.wait
	if wait <= 0 {
		wait = sessionRecordBusyTimeout
	}
	if w.deadline.IsZero() {
		return wait, true
	}
	left := w.deadline.Sub(lockNow())
	if left < time.Millisecond {
		return 0, false
	}
	return min(wait, left), true
}

// write runs fn under the wait's busy timeout and, with retry, once more
// when it gave up on another connection's lock and the budget has time left.
func (w hookLockWait) write(database *db.DB, fn func() error) error {
	wait, ok := w.attemptWait()
	if !ok {
		return errHookOutOfTime
	}
	if err := database.SetBusyTimeout(wait); err != nil {
		return err
	}
	err := fn()
	if !w.retry || !db.IsBusy(err) {
		return err
	}
	if wait, ok = w.attemptWait(); !ok {
		return err
	}
	if serr := database.SetBusyTimeout(wait); serr != nil {
		return errors.Join(err, serr)
	}
	return fn()
}

// agentStateWrite is what one event writes on its row besides what the
// event itself says: the state it maps to, the state it may only replace
// ("" = any), its time and its turn placement.
type agentStateWrite struct {
	state, onlyFrom string
	at              time.Time
	turn            hookTurn
}

// recordAgentEvent is the one entry point of a session event into the
// row's state (spec 2026-11-05 §3.5, PROJ-11): a hook's event (push) or a
// session adapter's pull event (sessionagent.Puller.Event) both land here,
// under recordAgentState's guards (the time order holds; a payload whose
// session id differs from the stored one writes nothing). The event decides
// the failure (a StopFailure's error) and whether it is the owner's prompt.
func recordAgentEvent(database *db.DB, rowID, workbenchID int64, ev hookEvent, w agentStateWrite) error {
	return recordAgentState(database, rowID, workbenchID, ev.SessionID, w.state, w.onlyFrom, agentFailure(ev),
		ev.Event == "UserPromptSubmit", w.at, w.turn)
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
	if turn.stop && turn.tasks.Present {
		turns, err := readTerminalAgentTurns(database, row.ID)
		if err != nil {
			return err
		}
		n, _ := backgroundAgents(turn.tasks, turns, "")
		if shells := backgroundShells(turn.tasks); n > 0 || shells > 0 {
			turn.background = sql.NullInt64{Int64: n, Valid: true}
			turn.shells = sql.NullInt64{Int64: shells, Valid: true}
		}
	}
	// The state first: under the hook's lock budget it is the write that
	// must land (board #988); the prompt's clear of the question follows.
	stateErr := recordAgentStateOver(database, row, workbenchID, sessionID, state, onlyFrom, failure, prompt, at, turn)
	var clearErr error
	if prompt {
		clearErr = clearChatQuestion(database, row, workbenchID, sessionID, at, turn.lock)
	}
	return errors.Join(stateErr, clearErr)
}

// recordAgentStateOver is recordAgentState's decision over the row it read:
// a repeat (at most a background report), a write the guards hold back, or
// writeAgentState. A failed prompt clear never skips it. An interrupt over a
// stored `waiting` is no repeat while its turn end would move
// (interruptMovesTurnEnd).
func recordAgentStateOver(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	rowID := row.ID
	switch {
	case repeatsAgentState(row, state, failure, prompt, turn.background, turn.shells) && !interruptMovesTurnEnd(row, turn):
		var reportErr error
		if turn.stop && turn.background.Valid {
			reportErr = writeBackgroundReport(database, rowID, workbenchID, sessionID, at, nil, nil, turn.lock)
		}
		return errors.Join(reportErr, recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at, turn.lock))
	case onlyFrom != "" && row.AgentState.String != onlyFrom,
		turn.notOverApproval && row.AgentState.String == agentStateApproval,
		!row.AgentStateAt.IsZero() && !at.After(row.AgentStateAt) && !stopEndsToolRun(row, turn):
		return recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at, turn.lock)
	}
	return writeAgentState(database, row, workbenchID, sessionID, state, onlyFrom, failure, prompt, at, turn)
}

// writeAgentState is recordAgentState's write over the row it read: the
// turn order's last check, then the guarded UPDATE, then the chat question's
// clear when a main-thread tool result ended a `waiting`.
func writeAgentState(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID, state, onlyFrom string,
	failure *db.AgentFailure, prompt bool, at time.Time, turn hookTurn) error {
	order := db.AgentOrder{Stop: turn.stop, Background: turn.background, Shells: turn.shells, Cwd: turn.cwd, NotOverApproval: turn.notOverApproval,
		ToolRun: turn.toolRun, Interrupt: turn.interrupt}
	var noteErr error
	if turn.toolRun || turn.interrupt {
		order.SeenTurnEnd = row.TurnEnd
		place := toolCallUnknown
		if row.TurnEnd.Valid {
			place = toolCallTurn(turn.transcriptPath, turn.toolUseID, row.TurnEnd.Int64)
		}
		if place == toolCallBeforeStop {
			// The ended turn's tool result or interrupt: no state, but its
			// cwd is the agent's.
			return recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at, turn.lock)
		}
		if turn.interrupt {
			order.TurnEnd, noteErr = interruptTurnEnd(row, turn, place)
		}
	}
	var written bool
	err := turn.lock.write(database, func() error {
		var err error
		written, err = setTerminalAgentState(database, row.ID, workbenchID, sessionID, state, at, onlyFrom, failure, prompt, order)
		return err
	})
	if err == nil && !written {
		// A guard held the write back after the read (a racing hook): the
		// cwd still goes, under its own guards.
		return errors.Join(noteErr, recordCwdAlone(database, row.ID, workbenchID, sessionID, turn.cwd, at, turn.lock))
	}
	if err != nil || !turn.toolRun || row.AgentState.String != agentStateWaiting {
		return errors.Join(noteErr, err)
	}
	return clearChatQuestion(database, row, workbenchID, sessionID, at, turn.lock)
}

// interruptTurnEnd is the turn end an interrupt's `waiting` stores with it
// (board #1019): no Stop follows an interrupt, and the tool hooks are async,
// so a parallel call's PostToolUse or the interrupted call's own PreToolUse
// can start after the interrupt's hook and would turn its `waiting` back
// into `working` though the agent is idle. The turn end is read from the
// transcript itself, never its size at the time this async hook runs
// (interruptedTurnEnd): from the interrupted call's tool_use on, the start of
// the first user message that is not a tool result — the interrupt's marker
// or the owner's next prompt — else the end of the last whole line. Every
// tool call of the interrupted turn sits before it and a later turn's calls
// after it, even when the next prompt (whose `working` may have been a
// repeat that left the time order unmoved) is already in the transcript. It
// is searched from the stored turn end, where the transcript must place the
// interrupted call after it (place, toolCallAfterStop), or with none stored
// from the transcript's start. Otherwise the turn end stays and the time
// order alone decides, with a turnEndNotMoved saying why (one stderr line, no
// content; none for an input with no transcript path).
func interruptTurnEnd(row *db.TerminalSession, turn hookTurn, place toolCallPlace) (sql.NullInt64, error) {
	if turn.transcriptPath == "" {
		return sql.NullInt64{}, nil // no transcript to place it in
	}
	from := int64(0)
	if row.TurnEnd.Valid {
		from = row.TurnEnd.Int64
	}
	end, found, ok := interruptedTurnEnd(turn.transcriptPath, turn.toolUseID, from)
	switch {
	case !ok:
		return sql.NullInt64{}, turnEndNotMoved{"transcript unreadable"}
	case !found, row.TurnEnd.Valid && place != toolCallAfterStop:
		return sql.NullInt64{}, turnEndNotMoved{"interrupted call not placed in the transcript"}
	}
	return sql.NullInt64{Int64: end, Valid: true}, nil
}

// interruptMovesTurnEnd: an interrupt whose turn end would differ from the
// stored one (board #1019). Over a stored `waiting` — a turn that opened
// without a UserPromptSubmit (a background notification) and was
// interrupted before any of its tool hooks landed — the state repeats, but
// the turn end must still be stored, or the interrupted turn's late tool
// hooks turn the `waiting` into `working`. A call the transcript places
// before the stored turn end, or an interrupt it cannot place, moves
// nothing and stays a repeat (writeAgentState reports the unplaced one only
// when it writes).
func interruptMovesTurnEnd(row *db.TerminalSession, turn hookTurn) bool {
	if !turn.interrupt {
		return false
	}
	place := toolCallUnknown
	if row.TurnEnd.Valid {
		if place = toolCallTurn(turn.transcriptPath, turn.toolUseID, row.TurnEnd.Int64); place == toolCallBeforeStop {
			return false
		}
	}
	end, err := interruptTurnEnd(row, turn, place)
	return err == nil && end.Valid && end != row.TurnEnd
}

// turnEndNotMoved is an interrupt whose `waiting` went without a turn end
// (interruptTurnEnd): reported apart, never a failed state write.
type turnEndNotMoved struct{ reason string }

func (e turnEndNotMoved) Error() string { return "interrupt: turn end not moved: " + e.reason }

// readTerminalAgentTurns is the Stop's read of the row's agent turns, made
// only with background_tasks to count against them; a seam for tests.
var readTerminalAgentTurns = (*db.DB).TerminalAgentTurns

// setTerminalAgentState is the state's write; a seam for tests.
var setTerminalAgentState = (*db.DB).SetTerminalAgentState

// recordCwdAlone records cwd on row rowID when no state write carries it
// (board #566): only when it differs from the row's, is reported after the
// row's and not before the run mark (AgentCwd.WouldRecord; read first, so
// the common case — the same folder — never waits for the write lock);
// SetTerminalAgentCwd repeats the guards. "" writes nothing. A failure is an
// agentCwdNotRecorded.
func recordCwdAlone(database *db.DB, rowID, workbenchID int64, sessionID, cwd string, at time.Time, lock hookLockWait) error {
	if cwd == "" {
		return nil
	}
	stored, err := database.TerminalAgentCwd(rowID)
	if err == nil && stored.WouldRecord(cwd, at) {
		err = lock.write(database, func() error {
			_, err := setTerminalAgentCwd(database, rowID, workbenchID, sessionID, cwd, at)
			return err
		})
	}
	if err != nil {
		return agentCwdNotRecorded{err}
	}
	return nil
}

// setTerminalAgentCwd is the cwd's write alone; a seam for tests.
var setTerminalAgentCwd = (*db.DB).SetTerminalAgentCwd

// clearChatQuestion drops row's chat question when one is stored: the read
// row says so first, so the common case (no question) never waits for the
// write lock; ClearChatQuestionBefore keeps a question asked at or after at.
func clearChatQuestion(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID string, at time.Time,
	lock hookLockWait) error {
	if row.ChatQuestionAt == "" {
		return nil
	}
	err := lock.write(database, func() error {
		return database.ClearChatQuestionBefore(row.ID, workbenchID, sessionID, at)
	})
	if err != nil {
		return chatQuestionNotCleared{err}
	}
	return nil
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
func recordBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count, shells *int64,
	lock hookLockWait) error {
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	at = at.Truncate(time.Millisecond) // the stored precision
	if row.AgentState.String != agentStateWaiting || (row.Background.Int64 <= 0 && row.BackgroundShells.Int64 <= 0) ||
		(!row.BackgroundAt.IsZero() && !at.After(row.BackgroundAt)) {
		return nil
	}
	return writeBackgroundReport(database, rowID, workbenchID, sessionID, at, count, shells, lock)
}

// writeBackgroundReport stamps agent_background_at with at and, with count,
// lowers agent_background to it, with shells agent_background_shells: a
// background report, never a transition.
func writeBackgroundReport(database *db.DB, rowID, workbenchID int64, sessionID string, at time.Time, count, shells *int64,
	lock hookLockWait) error {
	return lock.write(database, func() error {
		_, err := database.LowerTerminalBackground(rowID, workbenchID, sessionID, at, count, shells)
		return err
	})
}

// repeatsAgentState says the write would change nothing the guarded UPDATE
// lets through: a StopFailure with another error type is a change, and so is
// a prompt's `working` on a finished row (it clears finished_at; a tool
// run's `working` over `working` never does), and a `waiting` whose stored
// background count differs from background, the count the write stores
// (invalid for every `waiting` but a Stop that counted some).
func repeatsAgentState(row *db.TerminalSession, state string, failure *db.AgentFailure, prompt bool,
	background, shells sql.NullInt64) bool {
	switch {
	case row.AgentState.String != state:
		return false
	case state == agentStateWaiting && (row.Background != background || row.BackgroundShells != shells):
		return false
	case failure != nil:
		return row.AgentFailure != nil && row.AgentFailure.Error == failure.Error
	default:
		return state != "working" || !row.Finished || !prompt
	}
}
