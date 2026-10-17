package tools

import (
	"context"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/workbenchgit"
)

// CheckSessionOnWorkbench refuses a terminal session of another workbench.
func CheckSessionOnWorkbench(d *db.DB, p *db.Workbench, sessionID int64) error {
	row, err := d.GetTerminalSession(sessionID)
	if err != nil {
		return err
	}
	if !row.WorkbenchID.Valid || row.WorkbenchID.Int64 != p.ID {
		return fmt.Errorf("session %d is not on workbench %d", sessionID, p.ID)
	}
	return nil
}

// ReviewSessionFolder is the root of the folder the session's agent works in
// (its worktree when it has one, else the workbench folder); the diff
// reviewer CLI and annotate_changes snapshot the same folder.
func ReviewSessionFolder(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (string, error) {
	if err := CheckSessionOnWorkbench(d, p, sessionID); err != nil {
		return "", err
	}
	cwd, err := d.TerminalAgentCwd(sessionID)
	if err != nil {
		return "", err
	}
	folder, err := workbenchgit.ResolveFolder(ctx, workbenchgit.Options{Folder: p.FolderPath}, cwd.Path)
	if err != nil {
		return "", err
	}
	if folder.Root == "" {
		return p.FolderPath, nil
	}
	return folder.Root, nil
}
