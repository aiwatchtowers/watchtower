package cmd

import (
	"errors"
	"fmt"
	"os"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// briefCleanupLine is the brief's `Cleanup:` line (spec
// 2026-10-12-session-cleanup §10): the exact `workbench cleanup` command for
// the brief's own terminal session, the one the install's allow rule matches
// (devpack.CleanupCommand), with how to apply it. "" when the session is not
// known — no or an invalid env var, a gone row, a row of another workbench —
// or the binary path cannot be read; a read failure is one stderr line, never
// a failed brief.
func briefCleanupLine(database *db.DB, workbenchID int64) string {
	sessionID, ok, err := terminalSessionRowID()
	if err != nil || !ok {
		return "" // an invalid env var is already reported by recordTerminalSessionID
	}
	row, err := database.GetTerminalSession(sessionID)
	if err != nil {
		if !errors.Is(err, db.ErrTerminalSessionNotFound) {
			fmt.Fprintf(os.Stderr, "watchtower: workbench %d brief: cleanup line: %v\n", workbenchID, err)
		}
		return ""
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != workbenchID {
		return ""
	}
	bin, err := workbenchExecutable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "watchtower: workbench %d brief: cleanup line: %v\n", workbenchID, err)
		return ""
	}
	return "Cleanup: " + devpack.CleanupCommand(bin, sessionID) +
		" (lists what this session would remove; the same command with --apply removes it)"
}
