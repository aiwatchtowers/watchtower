package sessionreport

import (
	"context"
	"errors"

	"watchtower/internal/db"
)

// benchFolder is the workbench folder a session's report reads its merge
// verdicts and PR states in (spec §6.9, §6.10: the session's own folder):
// the PR cache key (workbench_pr_states.workbench_folder_id) and the
// repository git and gh run in. id 0: the workbench has no folder row, so
// there is no cache to read or write.
type benchFolder struct {
	id   int64
	path string
}

// folderOf is session sessionID's bench folder (db.SessionFolderID and
// SessionFolderPath: a row with no folder reads as the home folder), or the
// home folder for sessionID 0.
func folderOf(ctx context.Context, d *db.DB, workbenchID, sessionID int64) (benchFolder, error) {
	if sessionID == 0 {
		return homeFolder(ctx, d, workbenchID)
	}
	path, _, err := d.SessionFolderPath(ctx, sessionID)
	if err != nil {
		return benchFolder{}, err
	}
	id, err := d.SessionFolderID(ctx, sessionID)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return benchFolder{path: path}, nil
	}
	if err != nil {
		return benchFolder{}, err
	}
	return benchFolder{id: id, path: path}, nil
}

// homeFolder is workbench workbenchID's home folder; id 0 (and
// projects.folder_path) when the bench has no folder row.
func homeFolder(ctx context.Context, d *db.DB, workbenchID int64) (benchFolder, error) {
	f, err := d.HomeFolder(ctx, workbenchID)
	if err == nil {
		return benchFolder{id: f.ID, path: f.FolderPath}, nil
	}
	if !errors.Is(err, db.ErrWorkbenchNotFound) {
		return benchFolder{}, err
	}
	wb, err := d.GetWorkbench(workbenchID)
	if err != nil {
		return benchFolder{}, err
	}
	return benchFolder{path: wb.FolderPath}, nil
}

// folderPRStates is the PR cache of bench folder folderID of workbench
// workbenchID; a folder id 0 (a bench with no folder row) has no cache: an
// empty map, never a failed report.
func folderPRStates(d *db.DB, workbenchID, folderID int64) (map[string]db.PRState, error) {
	if folderID == 0 {
		return map[string]db.PRState{}, nil
	}
	return d.PRStates(workbenchID, folderID)
}
