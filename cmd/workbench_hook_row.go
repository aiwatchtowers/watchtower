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

// resolveHookRow is the terminal_sessions row a hook of agent runs in, named
// by the terminal env var (read through env). ok is false, with a nil error,
// when the hook has no row to act on: no or an unparsable variable for
// Codex, a deleted row, a row of another kind or without a workbench. For
// Claude Code the row must also be of workbench flagWorkbench (today's
// guard), and an unparsable variable is an error as before; a Codex row
// gives its own workbench and flagWorkbench is not read. err is a database
// read failure.
func resolveHookRow(d *db.DB, agent agentkind.Kind, flagWorkbench int64, env func(string) string) (db.TerminalSession, bool, error) {
	if !agentkind.IsAgent(string(agent)) {
		return db.TerminalSession{}, false, fmt.Errorf("unknown agent %q", briefClip(string(agent), 40))
	}
	raw := strings.TrimSpace(env(terminalSessionEnv))
	if raw == "" {
		return db.TerminalSession{}, false, nil
	}
	rowID, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || rowID <= 0 {
		if agent == agentkind.Codex {
			return db.TerminalSession{}, false, nil
		}
		return db.TerminalSession{}, false, fmt.Errorf("invalid %s %q", terminalSessionEnv, briefClip(raw, 40))
	}
	row, err := d.GetTerminalSession(rowID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return db.TerminalSession{}, false, nil
	}
	if err != nil {
		return db.TerminalSession{}, false, err
	}
	if row.Kind != string(agent) || !row.WorkbenchID.Valid || row.WorkbenchID.Int64 <= 0 ||
		(agent == agentkind.Claude && row.WorkbenchID.Int64 != flagWorkbench) {
		return db.TerminalSession{}, false, nil
	}
	return *row, true, nil
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
	row, ok, err = resolveHookRow(database, agentkind.Codex, 0, os.Getenv)
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
// records nothing yet: the Codex event mapping (spec §6.3, §6.4) consumes
// the row and event it returns. ok is false when there is no row or no
// event; a real failure is one stderr line prefixed with what.
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
