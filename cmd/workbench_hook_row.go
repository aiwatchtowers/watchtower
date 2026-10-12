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

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
)

// hookAgentFlag selects the agent a workbench hook runs for. `--agent codex`
// replaces `--workbench N` on every Codex hook command: the Codex hook lines
// are the same in every folder (one trust key per event), so the workbench
// comes from the terminal row at hook time (spec 2026-10-12 §4.2, §6.1).
const hookAgentFlag = "agent"

// errAgentWithWorkbench is the usage error for a hook given both an id flag
// and --agent.
var errAgentWithWorkbench = errors.New("--agent codex replaces --" + workbenchFlag + ": give one of them")

// addHookAgentFlag registers --agent on a workbench hook command.
func addHookAgentFlag(cmd *cobra.Command, v *string) {
	cmd.Flags().StringVar(v, hookAgentFlag, "",
		"run as a Codex hook (codex; the workbench comes from "+terminalSessionEnv+", instead of --"+workbenchFlag+")")
}

// hookAgentFor is the agent a hook invocation runs for: Claude Code without
// --agent (today's hooks, which take --workbench N), Codex for `--agent
// codex` without an id flag. Any other --agent value, or --agent next to
// --workbench or --project, is a usage error.
func hookAgentFor(cmd *cobra.Command, raw string) (agentkind.Kind, error) {
	fs := cmd.Flags()
	if !fs.Changed(hookAgentFlag) {
		return agentkind.Claude, nil
	}
	if k, _ := agentkind.Parse(raw); k != agentkind.Codex {
		return "", fmt.Errorf("unsupported --%s %q (only codex)", hookAgentFlag, briefClip(raw, 40))
	}
	if fs.Changed(workbenchFlag) || fs.Changed(legacyWorkbenchFlag) {
		return "", errAgentWithWorkbench
	}
	return agentkind.Codex, nil
}

// resolveCodexHookRow is the codex terminal_sessions row a Codex hook runs
// in, named by the terminal env var (read through env); the row gives its
// own workbench. ok is false, with a nil error, when the hook has no row to
// act on: no or an unparsable variable, a deleted row, a row of another kind
// or without a workbench. err is a database read failure.
func resolveCodexHookRow(d *db.DB, env func(string) string) (db.TerminalSession, bool, error) {
	raw := strings.TrimSpace(env(terminalSessionEnv))
	if raw == "" {
		return db.TerminalSession{}, false, nil
	}
	rowID, ok := positiveRowID(raw)
	if !ok { // not a row id of ours: no row to act on
		return db.TerminalSession{}, false, nil
	}
	row, err := d.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return db.TerminalSession{}, false, nil
	}
	if err != nil {
		return db.TerminalSession{}, false, err
	}
	if row.Kind != string(agentkind.Codex) || !row.WorkbenchID.Valid || row.WorkbenchID.Int64 <= 0 {
		return db.TerminalSession{}, false, nil
	}
	return *row, true, nil
}

// positiveRowID is raw as a terminal row id; false when it is not a
// positive integer.
func positiveRowID(raw string) (int64, bool) {
	id, err := strconv.ParseInt(raw, 10, 64)
	return id, err == nil && id > 0
}

// noteForeignCodexSession writes one stderr line when a Codex hook on row
// is dropped because the row stores another session id (spec I6: a stale or
// foreign start, a nested codex): which row, both ids, and what was dropped.
// Silent when the row has no id yet, the payload carries none, or the ids
// match.
func noteForeignCodexSession(w io.Writer, row db.TerminalSession, incoming, what string) {
	stored := row.ClaudeSessionID.String
	if !row.ClaudeSessionID.Valid || stored == "" || incoming == "" || incoming == stored {
		return
	}
	fmt.Fprintf(w, "watchtower: codex %s ignored: terminal session %d stores session %s, the hook came from session %s\n",
		what, row.ID, stored, briefClip(incoming, 40))
}

// codexHookRow opens the database with open and resolves the Codex row the
// hook runs in. Without the terminal env var nothing is opened. ok is false
// when there is no row to act on, the database stays closed then; a failure
// is one stderr line prefixed with what, and the hook still exits 0 (spec
// I3: a Codex hook never fails a turn).
func codexHookRow(stderr io.Writer, what string, open func() (*db.DB, error)) (database *db.DB, row db.TerminalSession, ok bool) {
	if strings.TrimSpace(os.Getenv(terminalSessionEnv)) == "" {
		return nil, db.TerminalSession{}, false
	}
	database, err := open()
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: %s: %v\n", what, err)
		return nil, db.TerminalSession{}, false
	}
	row, ok, err = resolveCodexHookRow(database, os.Getenv)
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: %s: %v\n", what, err)
	}
	if !ok {
		_ = database.Close()
		return nil, db.TerminalSession{}, false
	}
	return database, row, true
}

// openHookDB opens the database the way the state hooks do (migrating it
// when needed).
func openHookDB() (*db.DB, error) {
	_, database, err := openJiraCmdDB()
	return database, err
}

// readCodexHook resolves the Codex row a state, Stop or ask-guard hook runs
// in, then reads its event (at most limit bytes, waiting at most wait). It
// records nothing: the Codex event mapping (spec §6.3, §6.4) consumes the
// row and event it returns. ok is false when there is no row or no event; a
// real failure is one stderr line prefixed with what.
func readCodexHook(stdin io.Reader, stderr io.Writer, what string, wait time.Duration, limit int64,
	open func() (*db.DB, error)) (row db.TerminalSession, ev hookEvent, ok bool) {
	database, row, ok := codexHookRow(stderr, what, open)
	if !ok {
		return db.TerminalSession{}, hookEvent{}, false
	}
	_ = database.Close()
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	ev, err := readHookEvent(ctx, stdin, limit, agentkind.Codex)
	cancel()
	if err != nil {
		if !errors.Is(err, io.EOF) {
			fmt.Fprintf(stderr, "watchtower: %s: reading the hook input: %v\n", what, err)
		}
		return db.TerminalSession{}, hookEvent{}, false
	}
	return row, ev, true
}
