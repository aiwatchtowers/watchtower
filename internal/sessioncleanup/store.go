package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// DBStore is the Store over the Watchtower database. Every method only
// reads.
type DBStore struct {
	DB *db.DB
	// Now stands in for the clock an unreadable activity stamp is read as;
	// nil = time.Now.
	Now func() time.Time
}

var _ Store = DBStore{}

// ErrStandaloneSession is a terminal session of no workbench: there is no
// repository to clean up.
var ErrStandaloneSession = errors.New("not a workbench session")

// CleanupSession reads the session's workbench and its start. A missing
// row keeps db.ErrTerminalSessionNotFound in the chain; an unreadable
// created_at is an error, never a zero start (a zero start would make
// everything the session saw look younger than it); a standalone terminal
// has no workbench to clean up. A placed row (worktree_branch set) carries
// its folder_path and worktree_branch; a row being deleted its
// delete_requested_at as Ended; a row started for a workbench folder that
// folder's path and whether it left the bench.
func (s DBStore) CleanupSession(ctx context.Context, sessionID int64) (SessionInfo, error) {
	row, err := s.DB.GetTerminalSession(sessionID)
	if err != nil {
		return SessionInfo{}, fmt.Errorf("session %d: %w", sessionID, err)
	}
	if !row.WorkbenchID.Valid {
		return SessionInfo{}, fmt.Errorf("session %d: %w", sessionID, ErrStandaloneSession)
	}
	start, err := s.DB.TerminalSessionStart(ctx, sessionID)
	if err != nil {
		return SessionInfo{}, err
	}
	ended, err := s.DB.TerminalDeleteRequestedAt(ctx, sessionID)
	if err != nil {
		return SessionInfo{}, fmt.Errorf("session %d: %w", sessionID, err)
	}
	info := SessionInfo{ID: row.ID, WorkbenchID: row.WorkbenchID.Int64, CreatedAt: start, Kind: row.Kind}
	if t, ok := parseRFC3339(ended); ok {
		info.Ended = t
	}
	if row.WorktreeBranch.Valid {
		info.PlacedCwd, info.PlacedBranch = row.FolderPath, row.WorktreeBranch.String
	}
	if row.WorkbenchFolderID.Valid {
		f, err := s.DB.WorkbenchFolderByID(ctx, row.WorkbenchFolderID.Int64)
		if err != nil {
			return SessionInfo{}, fmt.Errorf("session %d: reading its folder: %w", sessionID, err)
		}
		info.Folder, info.FolderRemoved = f.FolderPath, f.RemovedAt.Valid
	}
	return info, nil
}

// SessionWorktrees is db.DB.SessionWorktrees.
func (s DBStore) SessionWorktrees(ctx context.Context, sessionID int64) ([]db.SessionWorktree, error) {
	return s.DB.SessionWorktrees(ctx, sessionID)
}

// SessionTargetBranches is db.DB.SessionTargetBranches.
func (s DBStore) SessionTargetBranches(ctx context.Context, sessionID int64) ([]string, error) {
	return s.DB.SessionTargetBranches(ctx, sessionID)
}

// WorkbenchFolder is the workbench's folder_path (its home folder).
func (s DBStore) WorkbenchFolder(_ context.Context, workbenchID int64) (string, error) {
	wb, err := s.DB.GetWorkbench(workbenchID)
	if err != nil {
		return "", err
	}
	return wb.FolderPath, nil
}

// WorkbenchFolders is every workbench's folder_path and every folder row
// of every workbench, the removed ones included.
func (s DBStore) WorkbenchFolders(ctx context.Context) ([]string, error) {
	wbs, err := s.DB.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	folders, err := s.hasFolderRows()
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(wbs))
	for _, wb := range wbs {
		out = append(out, wb.FolderPath)
		if !folders {
			continue
		}
		rows, err := s.DB.WorkbenchFolders(ctx, wb.ID, true)
		if err != nil {
			return nil, err
		}
		for _, f := range rows {
			out = append(out, f.FolderPath)
		}
	}
	return out, nil
}

// BenchFolders is the workbench's home folder (folder_path) first, then its
// other live folders by position.
func (s DBStore) BenchFolders(ctx context.Context, workbenchID int64) ([]string, error) {
	home, err := s.WorkbenchFolder(ctx, workbenchID)
	if err != nil {
		return nil, err
	}
	out := []string{home}
	folders, err := s.hasFolderRows()
	if err != nil || !folders {
		return out, err
	}
	rows, err := s.DB.WorkbenchFolders(ctx, workbenchID, false)
	if err != nil {
		return nil, err
	}
	for _, f := range rows {
		if !strings.EqualFold(f.FolderPath, home) {
			out = append(out, f.FolderPath)
		}
	}
	return out, nil
}

// hasFolderRows: the database has workbench_folders (migration 00209). The
// cleanup opens a database without migrating it; an older one has only
// folder_path.
func (s DBStore) hasFolderRows() (bool, error) {
	return s.DB.HasColumns("workbench_folders", "workbench_id", "folder_path", "removed_at")
}

// AgentSessionIDs is db.DB.AgentSessionIDs.
func (s DBStore) AgentSessionIDs(ctx context.Context, sessionID int64) ([]db.AgentSessionID, error) {
	return s.DB.AgentSessionIDs(ctx, sessionID)
}

// AgentSessionIDOwners is db.DB.AgentSessionIDOwners.
func (s DBStore) AgentSessionIDOwners(ctx context.Context, uuids []string) (map[string][]int64, error) {
	return s.DB.AgentSessionIDOwners(ctx, uuids)
}

// WorkbenchSessionWorktrees is db.DB.WorkbenchSessionWorktrees.
func (s DBStore) WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error) {
	return s.DB.WorkbenchSessionWorktrees(ctx, workbenchID)
}

// SessionWorktreeOwners is db.DB.SessionWorktreeOwners.
func (s DBStore) SessionWorktreeOwners(ctx context.Context) (map[string][]int64, error) {
	return s.DB.SessionWorktreeOwners(ctx) //nolint:wrapcheck // names the read
}

// AllSessionActivity is every terminal session with its agent's working
// directory (agent_cwd, board #565). A stamp that is stored but does not
// read is taken as now: the session counts as active, so what it may be
// using is kept (fail closed); a NULL agent_state_at is never reported.
func (s DBStore) AllSessionActivity(ctx context.Context) ([]SessionActivity, error) {
	rows, err := s.DB.ListTerminalSessionActivity(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	out := make([]SessionActivity, 0, len(rows))
	for _, r := range rows {
		out = append(out, activityOf(r, now))
	}
	return out, nil
}

// SessionActivityOf is AllSessionActivity's row of one session, read by id
// (the last check before a destructive step); false when there is no row.
func (s DBStore) SessionActivityOf(ctx context.Context, id int64) (SessionActivity, bool, error) {
	r, ok, err := s.DB.TerminalSessionActivityOf(ctx, id)
	if err != nil || !ok {
		return SessionActivity{}, false, err //nolint:wrapcheck // names the read
	}
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	return activityOf(r, now), true, nil
}

// activityOf reads a stored row, the stamps by the one shared rule.
func activityOf(r db.TerminalSessionActivity, now func() time.Time) SessionActivity {
	return SessionActivity{
		ID: r.ID, WorkbenchID: r.WorkbenchID, Title: r.Title, AgentCwd: r.AgentCwd,
		ReportedAt: activityStamp(r.AgentStateAt, now, db.ParseActivityStamp),
		LastActive: activityStamp(r.LastActiveAt, now, db.ParseActivityStamp),
		Finished:   r.Finished, DeleteRequested: r.DeleteRequested, Kind: r.Kind, Folder: r.Folder,
	}
}

// WorktreeLastSeen is the database's newest ledger sighting of root.
func (s DBStore) WorktreeLastSeen(ctx context.Context, root string) (time.Time, bool, error) {
	return s.DB.WorktreeLastSeen(ctx, root)
}

// activityStamp reads a stored stamp: zero when none is stored, now when
// one is stored but does not parse.
func activityStamp(raw string, now func() time.Time, parse func(string) (time.Time, bool)) time.Time {
	if raw == "" {
		return time.Time{}
	}
	if at, ok := parse(raw); ok {
		return at
	}
	return now()
}

func parseRFC3339(s string) (time.Time, bool) {
	at, err := time.Parse(time.RFC3339, s)
	return at, err == nil
}
