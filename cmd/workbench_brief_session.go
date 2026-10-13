package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"watchtower/internal/agentkind"
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

// sessionSwitchSources are the SessionStart sources that may put the
// terminal on another conversation than the stored one: /clear starts a new
// session id, a resume (the --resume launch, --continue or the in-session
// /resume picker) continues the picked one, a fork branches into a new one,
// and compaction is taken whether or not it rotates the id (a same id is a
// no-op). "startup" is left out on purpose: the launch's own id is already
// stored, and a nested headless `claude -p` the agent runs from its shell
// inherits the env var and starts with "startup" — it must not take the row.
var sessionSwitchSources = map[string]bool{"clear": true, "compact": true, "resume": true, "fork": true}

// newRunSources are the SessionStart sources of a new process run — the
// Desktop's launch (`--session-id`) and its relaunch (`--resume`): the row's
// agent state from the previous run is cleared (board #312), and with the
// session state hooks the run is marked (board #396). /clear and compaction
// — a manual /compact or one Claude Code runs by itself while idle —
// continue the same run, so its state stays.
var newRunSources = map[string]bool{"startup": true, "resume": true}

// recordTerminalSessionID keeps an embedded terminal's row on the Claude
// Code conversation it is in (board #160): the Desktop relaunches the stored
// id, so after /clear it would otherwise resume the pre-clear conversation.
// A new process run also starts the row's agent state anew
// (`newRunSources`), after the id moved, so the write's guard sees the final
// id; a nested `claude -p` has another id and writes nothing. nil when there is nothing
// to record — no env var (not a Desktop-launched session), another source,
// a row that is gone or already current; an error means the row may still
// name the previous conversation or keep the previous run's state. Never
// panics: the hook must exit 0.
func recordTerminalSessionID(stdin io.Reader, workbenchID int64) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	rowID, ok, err := terminalSessionRowID()
	if !ok || err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), sessionStartInputWait)
	hook, err := readHookEvent(ctx, stdin, hookStdinLimit, agentkind.Claude)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	switches, newRun := sessionSwitchSources[hook.Source], newRunSources[hook.Source]
	if !switches && !newRun {
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
	return applySessionStart(database, rowID, workbenchID, hook.SessionID, switches, newRun)
}

// applySessionStart moves row rowID to conversation sessionID when the
// source switched conversations, and on a new run marks it when the
// workbench's folder has the session state hooks (MarkTerminalAgentRun: the
// hooks run, no turn yet — PROJ-12's Return, board #396), else clears the
// previous run's state without a stamp.
func applySessionStart(database *db.DB, rowID, workbenchID int64, sessionID string, switches, newRun bool) error {
	// Read first: a relaunch without the state hooks and with nothing to
	// clear must not wait for the write lock.
	row, err := database.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return nil // deleted while its terminal ran
	}
	if err != nil {
		return err
	}
	if row.Kind != string(agentkind.Claude) {
		// A nested claude run from another agent's row (a codex shell)
		// inherits the env var: it never takes that row, not even a NULL id.
		return nil
	}
	writes, hooksErr := planSessionStart(database, row, workbenchID, sessionID, switches, newRun)
	if err := writes.apply(database, rowID, workbenchID, sessionID); err != nil {
		return errors.Join(err, hooksErr)
	}
	return hooksErr
}

// sessionStartWrites is what a SessionStart hook writes on its row.
type sessionStartWrites struct {
	moveID, markRun, clearState bool
}

// planSessionStart decides the writes for row. A nested `claude -p`
// (another id, no switch) owns no run of the row and is not even asked
// about the hooks; a failed read of the hooks neither marks nor clears,
// but the id still moves (board #160) and the error is returned with the
// plan.
func planSessionStart(database *db.DB, row *db.TerminalSession, workbenchID int64, sessionID string,
	switches, newRun bool) (sessionStartWrites, error) {
	moveID := switches && row.ClaudeSessionID.String != sessionID
	if !newRun || (!moveID && row.ClaudeSessionID.String != sessionID) {
		return sessionStartWrites{moveID: moveID}, nil
	}
	hooks, err := workbenchHasStateHooks(database, workbenchID)
	if err != nil {
		return sessionStartWrites{moveID: moveID}, fmt.Errorf("reading the workbench's state hooks: %w", err)
	}
	return sessionStartWrites{moveID: moveID, markRun: hooks, clearState: !hooks && hasRunState(row)}, nil
}

// hasRunState says the row keeps anything of a run: a state, its stamp or
// a turn order.
func hasRunState(row *db.TerminalSession) bool {
	return row.AgentState.Valid || !row.AgentStateAt.IsZero() || row.TurnEnd.Valid || row.ToolRun
}

// apply makes the writes, the id move first so the mark's or the clear's
// guard sees the final id; with none it does not wait for the write lock.
func (w sessionStartWrites) apply(database *db.DB, rowID, workbenchID int64, sessionID string) error {
	if !w.moveID && !w.markRun && !w.clearState {
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	if w.moveID {
		if _, err := database.SetTerminalClaudeSessionID(rowID, workbenchID, sessionID); err != nil {
			return err
		}
	}
	if w.markRun {
		if _, err := database.MarkTerminalAgentRun(rowID, workbenchID, sessionID, hookNow()); err != nil {
			return fmt.Errorf("marking the new run: %w", err)
		}
	}
	if w.clearState {
		if _, err := database.ClearTerminalAgentState(rowID, workbenchID, sessionID); err != nil {
			return fmt.Errorf("clearing the previous run's agent state: %w", err)
		}
	}
	return nil
}

// sessionStartPlan is the id write a Codex SessionStart makes on its row
// (spec 2026-10-12-codex-workbench-agent §5).
type sessionStartPlan string

const (
	// sessionStartSet stores the first id over the row's NULL one
	// (SetTerminalAgentSessionID) and marks the run.
	sessionStartSet sessionStartPlan = "set"
	// sessionStartMark marks a new run of the stored id.
	sessionStartMark sessionStartPlan = "mark"
	// sessionStartMove moves the row to another id (/clear, a fork, a
	// resume onto another session); a resume also marks the run.
	sessionStartMove sessionStartPlan = "move"
	// sessionStartNone writes no id and no mark.
	sessionStartNone sessionStartPlan = "none"
)

// codexSessionSource is ev's source as the Codex mapping reads it: an
// unknown or missing source is a startup.
func codexSessionSource(ev hookEvent) string {
	if sessionSwitchSources[ev.Source] || newRunSources[ev.Source] {
		return ev.Source
	}
	return "startup"
}

// planCodexSessionStart decides a Codex SessionStart's write on a row
// storing stored. A row with no id yet takes the payload's on any source.
// The stored id on a new run (startup, resume) is marked; a compaction keeps
// the same id and the live turn's state (capture note, answer 3). Another
// id moves the row on a switch source and is a stale or foreign start on a
// startup. A missing or non-UUID id writes nothing.
func planCodexSessionStart(stored sql.NullString, ev hookEvent) sessionStartPlan {
	source := codexSessionSource(ev)
	switch {
	case !terminal.IsSessionID(ev.SessionID):
		return sessionStartNone
	case !stored.Valid:
		return sessionStartSet
	case stored.String == ev.SessionID && newRunSources[source]:
		return sessionStartMark
	case stored.String != ev.SessionID && sessionSwitchSources[source]:
		return sessionStartMove
	}
	return sessionStartNone
}

// recordCodexSessionStart is the Codex SessionStart's write on row (spec
// §5), read from stdin; database is open. nil when there is nothing to
// record: no input, a missing or non-UUID session id, a stale start (one
// stderr line names a start dropped for another stored id). Never
// panics: the brief is printed after it whatever it returns.
func recordCodexSessionStart(stdin io.Reader, stderr io.Writer, database *db.DB, row db.TerminalSession) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), sessionStartInputWait)
	ev, err := readHookEvent(ctx, stdin, hookStdinLimit, agentkind.Codex)
	cancel()
	if errors.Is(err, io.EOF) {
		return nil // a manual run with stdin closed
	}
	if err != nil {
		return fmt.Errorf("reading the hook input: %w", err)
	}
	if planCodexSessionStart(row.ClaudeSessionID, ev) == sessionStartNone {
		noteForeignCodexSession(stderr, row, ev.SessionID, "SessionStart ("+codexSessionSource(ev)+")")
	}
	return applyCodexSessionStart(database, row, ev)
}

// applyCodexSessionStart makes planCodexSessionStart's writes on row: the id
// first, so the mark's and the path's guards see the final id, then the
// run's mark (a codex row has its state hooks by construction, spec §6.3),
// then the absolute transcript path every accepted start stores. With
// nothing to write it does not wait for the write lock.
func applyCodexSessionStart(database *db.DB, row db.TerminalSession, ev hookEvent) error {
	plan := planCodexSessionStart(row.ClaudeSessionID, ev)
	path := codexPathToStore(row, ev, plan)
	if plan == sessionStartNone && path == "" {
		return nil
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	if moved, err := writeCodexSessionID(database, row, ev, plan); err != nil || !moved {
		return err
	}
	wb := row.WorkbenchID.Int64
	if codexStartMarksRun(plan, ev) {
		if _, err := database.MarkTerminalAgentRun(row.ID, wb, ev.SessionID, hookNow()); err != nil {
			return fmt.Errorf("marking the new run: %w", err)
		}
	}
	if path != "" {
		if _, err := database.SetTerminalTranscriptPath(row.ID, wb, ev.SessionID, path); err != nil {
			return fmt.Errorf("storing the transcript path: %w", err)
		}
	}
	return nil
}

// writeCodexSessionID is the plan's id write: a NULL id takes the payload's
// (with its transcript path) through SetTerminalAgentSessionID, which never
// fills a claude row; a move goes through the Claude Code switch write. ok is
// false when a set lost a race (another start stored an id first): nothing
// more is written then.
func writeCodexSessionID(database *db.DB, row db.TerminalSession, ev hookEvent, plan sessionStartPlan) (ok bool, err error) {
	switch plan {
	case sessionStartSet:
		return database.SetTerminalAgentSessionID(row.ID, row.WorkbenchID.Int64, ev.SessionID,
			absTranscriptPath(ev.TranscriptPath))
	case sessionStartMove:
		_, err := database.SetTerminalClaudeSessionID(row.ID, row.WorkbenchID.Int64, ev.SessionID)
		return err == nil, err
	case sessionStartMark, sessionStartNone:
	}
	return true, nil
}

// codexStartMarksRun: the start begins a new run of the row — its first id,
// the stored id's startup or resume, or a resume onto another session.
func codexStartMarksRun(plan sessionStartPlan, ev hookEvent) bool {
	switch plan {
	case sessionStartSet, sessionStartMark:
		return true
	case sessionStartMove:
		return newRunSources[codexSessionSource(ev)]
	case sessionStartNone:
	}
	return false
}

// codexPathToStore is the transcript path the start stores after its id
// write, "" for none: a relative or missing path, a set (it stores the path
// with the id), a start of another session, or a path already stored.
func codexPathToStore(row db.TerminalSession, ev hookEvent, plan sessionStartPlan) string {
	path := absTranscriptPath(ev.TranscriptPath)
	switch {
	case path == "" || plan == sessionStartSet:
		return ""
	case plan == sessionStartMove:
		return path // the move cleared the old session's path
	case row.ClaudeSessionID.String == ev.SessionID && row.TranscriptPath.String != path:
		return path
	}
	return ""
}

// absTranscriptPath is a hook's transcript path when it is absolute, "" for
// a relative or missing one (never stored: the readers open it as is).
func absTranscriptPath(p string) string {
	if !filepath.IsAbs(p) {
		return ""
	}
	return p
}
