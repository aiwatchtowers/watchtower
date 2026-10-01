package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/terminal"
)

// terminalSessionEnv names the terminal_sessions row a Desktop-launched
// claude runs in; TerminalCenter sets it for a claude row's process only.
const terminalSessionEnv = "WATCHTOWER_TERMINAL_SESSION_ID"

// sessionStartInputMax bounds the hook payload read (a few hundred bytes in
// practice).
const sessionStartInputMax = 64 * 1024

// sessionStartInputWait bounds the wait for it: Claude Code writes the
// payload and closes stdin at once, and the brief must never stall. A var
// for tests.
var sessionStartInputWait = time.Second

// sessionStartInput is the part of Claude Code's SessionStart hook payload
// the brief reads.
type sessionStartInput struct {
	SessionID string `json:"session_id"`
	Source    string `json:"source"`
}

// sessionSwitchSources are the SessionStart sources that may put the
// terminal on another conversation than the one it was launched with: /clear
// starts a new session id, and a resume (the --resume launch or the in-session
// /resume picker) may continue under another id. "startup" is left out on
// purpose: the launch's own id is already stored, and a nested headless
// `claude -p` the agent runs from its shell inherits the env var and starts
// with "startup" — it must not take the row over.
var sessionSwitchSources = map[string]bool{"clear": true, "compact": true, "resume": true}

// recordTerminalSessionID keeps an embedded terminal's row on the Claude
// Code conversation it is in (board #160): the Desktop relaunches the stored
// id, so after /clear it would otherwise resume the pre-clear conversation.
// Runs only under the env var, i.e. inside a Desktop-launched project
// session; best effort — a failure is one stderr line and the brief is
// printed as before.
func recordTerminalSessionID(in io.Reader, stderr io.Writer, rawProject string) {
	raw, ok := os.LookupEnv(terminalSessionEnv)
	if !ok {
		return
	}
	rowID, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	projectID, perr := strconv.ParseInt(strings.TrimSpace(rawProject), 10, 64)
	if err != nil || rowID <= 0 || perr != nil || projectID <= 0 {
		return
	}
	hook, err := readSessionStartInput(in)
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: project %d brief: terminal session %d: %v\n", projectID, rowID, err)
		return
	}
	if !sessionSwitchSources[hook.Source] || !terminal.IsSessionID(hook.SessionID) {
		return
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: project %d brief: terminal session %d: %v\n", projectID, rowID, err)
		return
	}
	defer database.Close()
	if _, err := database.SetTerminalClaudeSessionID(rowID, projectID, hook.SessionID); err != nil {
		fmt.Fprintf(stderr, "watchtower: project %d brief: %v\n", projectID, err)
	}
}

// readSessionStartInput decodes the hook payload from in. A terminal (a
// manual run) is never read; a payload that does not arrive within
// sessionStartInputWait is an error, never a stall; an empty input is none.
func readSessionStartInput(in io.Reader) (sessionStartInput, error) {
	var hook sessionStartInput
	if f, ok := in.(*os.File); ok {
		if info, err := f.Stat(); err == nil && info.Mode()&os.ModeCharDevice != 0 {
			return hook, nil
		}
	}
	type result struct {
		data []byte
		err  error
	}
	done := make(chan result, 1)
	go func() {
		data, err := io.ReadAll(io.LimitReader(in, sessionStartInputMax))
		done <- result{data, err}
	}()
	select {
	case r := <-done:
		if r.err != nil {
			return hook, fmt.Errorf("reading the hook input: %w", r.err)
		}
		if len(strings.TrimSpace(string(r.data))) == 0 {
			return hook, nil // a manual run with stdin closed
		}
		if err := json.Unmarshal(r.data, &hook); err != nil {
			return hook, fmt.Errorf("decoding the hook input: %w", err)
		}
		return hook, nil
	case <-time.After(sessionStartInputWait):
		return hook, fmt.Errorf("no hook input within %s", sessionStartInputWait)
	}
}
