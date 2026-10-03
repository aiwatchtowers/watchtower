package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

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
	Long: "The UserPromptSubmit, Notification, PostToolUse and StopFailure hook installed by\n" +
		"`integrate claude-code --workbench N`: it reads the hook input on stdin and stores\n" +
		"working / waiting / approval on the Desktop terminal's row named by\n" +
		"WATCHTOWER_TERMINAL_SESSION_ID, so the Workbench shows it. Without that variable it\n" +
		"does nothing. It never prints to stdout and always exits 0.",
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

// sessionStateInput is the part of Claude Code's hook input the state hook
// reads; every other field is ignored.
type sessionStateInput struct {
	HookEventName    string `json:"hook_event_name"`
	SessionID        string `json:"session_id"`
	NotificationType string `json:"notification_type"`
	// AgentID is set when the hook fired inside a subagent.
	AgentID string `json:"agent_id"`
}

// agentStateFor maps a hook event to the state it records. onlyFrom, when
// set, is the stored state the write requires (a subagent's PostToolUse,
// recordHookAgentState). A main-thread PostToolUse means a tool just ran: it clears "needs approval" after a
// granted permission and "waiting" when a turn started without a prompt (a
// teammate or background-task message, a wakeup fires no UserPromptSubmit);
// one stamped before the stop's "waiting" is an older event and writes
// nothing. ok is false for an event that records nothing — an unknown event
// or notification type, or a missing one.
func agentStateFor(event, notificationType string) (state, onlyFrom string, ok bool) {
	switch event {
	case "UserPromptSubmit":
		return agentStateWorking, "", true
	case "Stop", "StopFailure":
		return agentStateWaiting, "", true
	case "PostToolUse":
		return agentStateWorking, "", true
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
	if in.AgentID != "" && in.HookEventName == "PostToolUse" {
		// A background subagent works on after the main turn stopped to wait
		// for the owner: its tool results clear only a granted permission.
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
	return recordAgentState(database, rowID, workbenchID, in.SessionID, state, onlyFrom, at)
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
// write repeats every guard, so a race with another hook stays correct. nil
// when a guard holds the write back — a gone row is not an error.
func recordAgentState(database *db.DB, rowID, workbenchID int64, sessionID, state, onlyFrom string, at time.Time) error {
	if !terminal.IsSessionID(sessionID) {
		return fmt.Errorf("the hook input carries no session id (%q)", briefClip(sessionID, 40))
	}
	at = at.Truncate(time.Millisecond) // the stored precision
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil // deleted while its terminal ran
	}
	if err != nil {
		return err
	}
	switch {
	case row.WorkbenchID.Int64 != workbenchID || row.Kind != "claude",
		row.ClaudeSessionID.String != sessionID,
		row.AgentState.String == state,
		onlyFrom != "" && row.AgentState.String != onlyFrom,
		!row.AgentStateAt.IsZero() && !at.After(row.AgentStateAt):
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err = database.SetTerminalAgentState(rowID, workbenchID, sessionID, state, at, onlyFrom)
	return err
}
