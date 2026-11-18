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
// §6.13, D37): before session row's agent launches in dir, the workbench id
// installed there is compared with the row's workbench wb. A place
// installed for another workbench only — a merged bench's folder or
// worktree the merge's reinstall missed — gets wb's install first
// (d.Reinstall), the install of each id whose workbench is gone taken out;
// the mismatch is logged as install_mismatch. A place with wb's install,
// or with none (the start behaves as it always did), is left alone. A
// failed reinstall is logged and returned; the launch goes on either way.
// reinstalled reports whether the reinstall ran.
func EnsureInstall(ctx context.Context, d Deps, row, wb int64, dir string, agent agentkind.Kind) (reinstalled bool, err error) {
	if d.Reinstall == nil {
		return false, nil
	}
	if ok, herr := devpack.HasCoreStateHooks(dir, wb); herr != nil || ok {
		return false, nil //nolint:nilerr // unreadable settings: the start's own checks report them
	}
	ids, err := devpack.InstalledWorkbenchIDs(dir)
	if err != nil || len(ids) == 0 {
		return false, nil //nolint:nilerr // as above
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
