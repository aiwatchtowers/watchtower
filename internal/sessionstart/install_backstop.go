package sessionstart

import (
	"context"
	"database/sql"
	"errors"
	"log"

	"watchtower/internal/agentkind"
	"watchtower/internal/devpack"
)

// EnsureInstall is the launch backstop after a bench merge (spec 2026-11-18
// §6.13, D37): before session row's agent launches in dir, the workbench ids
// installed there are compared with the row's workbench wb. A place whose
// install names any other id — a merged bench's folder or worktree the
// merge's reinstall missed, even beside wb's own — is repaired first
// (d.Reinstall): the install of each id whose workbench is gone taken out,
// wb's put in; the mismatch is logged as install_mismatch. A place with only
// wb's install (a partial one is Repair's), or with none (the start behaves
// as it always did), is left alone; the Desktop's WorkbenchInstallCheck
// reads it the same way. A failed reinstall is logged and returned; the
// launch goes on either way. reinstalled reports whether the reinstall ran.
func EnsureInstall(ctx context.Context, d Deps, row, wb int64, dir string, agent agentkind.Kind) (reinstalled bool, err error) {
	if d.Reinstall == nil {
		return false, nil
	}
	ids, err := devpack.InstalledWorkbenchIDs(dir)
	if err != nil || !namesAnother(ids, wb) {
		return false, nil //nolint:nilerr // unreadable settings: the start's own checks report them
	}
	var stale []int64
	for _, id := range ids {
		var one int
		qerr := d.DB.QueryRowContext(ctx, `SELECT 1 FROM projects WHERE id = ?`, id).Scan(&one)
		if errors.Is(qerr, sql.ErrNoRows) {
			stale = append(stale, id)
		}
	}
	// By ids and class only (FILES-01): no path in the log.
	log.Printf("sessionstart: session %d: install_mismatch: installed for workbench %v, the row's is %d; reinstalling", row, ids, wb)
	if err := d.Reinstall(ctx, wb, dir, agent, stale); err != nil {
		log.Printf("sessionstart: session %d: the reinstall failed (%s); launching anyway", row, errClass(err))
		return true, err
	}
	return true, nil
}

// namesAnother reports whether ids holds a workbench id other than wb.
func namesAnother(ids []int64, wb int64) bool {
	for _, id := range ids {
		if id != wb {
			return true
		}
	}
	return false
}
