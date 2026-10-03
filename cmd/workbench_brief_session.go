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

	"watchtower/internal/db"
	"watchtower/internal/terminal"
	"watchtower/internal/tools"
)

// terminalSessionEnv names the terminal_sessions row a Desktop-launched
// claude runs in; TerminalCenter sets it for a claude row's process only (a
// dual path with Swift `TerminalLaunch.sessionRowEnv`). The ask tools read
// the same variable.
const terminalSessionEnv = tools.TerminalSessionEnv

// sessionRecordBusyTimeout bounds the wait for the write lock: a daemon
// holding it fails the record as one line instead of eating the hook's
// 10 s budget before the brief is printed.
const sessionRecordBusyTimeout = time.Second

// sessionStartInputWait bounds the wait for the hook input: Claude Code
// writes it and closes stdin at once. A var for tests.
var sessionStartInputWait = time.Second

// sessionStartInput is the part of Claude Code's SessionStart hook input the
// brief reads.
type sessionStartInput struct {
	SessionID string `json:"session_id"`
	Source    string `json:"source"`
}

// sessionSwitchSources are the SessionStart sources that may put the
// terminal on another conversation than the stored one: /clear starts a new
// session id, a resume (the --resume launch, --continue or the in-session
// /resume picker) continues the picked one, a fork branches into a new one,
// and compaction is taken whether or not it rotates the id (a same id is a
// no-op). "startup" is left out on purpose: the launch's own id is already
// stored, and a nested headless `claude -p` the agent runs from its shell
// inherits the env var and starts with "startup" — it must not take the row.
var sessionSwitchSources = map[string]bool{"clear": true, "compact": true, "resume": true, "fork": true}

// recordTerminalSessionID keeps an embedded terminal's row on the Claude
// Code conversation it is in (board #160): the Desktop relaunches the stored
// id, so after /clear it would otherwise resume the pre-clear conversation.
// nil when there is nothing to record — no env var (not a Desktop-launched
// session), another source, a row that is gone or already current; an error
// means the row may still name the previous conversation. Never panics: the
// hook must exit 0.
func recordTerminalSessionID(stdin io.Reader, workbenchID int64) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	raw, ok := os.LookupEnv(terminalSessionEnv)
	if !ok {
		return nil
	}
	rowID, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || rowID <= 0 {
		return fmt.Errorf("invalid %s %q", terminalSessionEnv, briefClip(raw, 40))
	}
	ctx, cancel := context.WithTimeout(context.Background(), sessionStartInputWait)
	hook, err := readHookInput[sessionStartInput](ctx, stdin)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	if !sessionSwitchSources[hook.Source] {
		return nil
	}
	if !terminal.IsSessionID(hook.SessionID) {
		return fmt.Errorf("the %s hook input carries no session id (%q)", hook.Source, briefClip(hook.SessionID, 40))
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	// Read first: every relaunch resumes the stored id, and that common
	// case must not wait for the write lock.
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil // deleted while its terminal ran
	}
	if err != nil {
		return err
	}
	if row.ClaudeSessionID.String == hook.SessionID {
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	_, err = database.SetTerminalClaudeSessionID(rowID, workbenchID, hook.SessionID)
	return err
}
