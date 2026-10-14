package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
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
// has no workbench to clean up.
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
	return SessionInfo{ID: row.ID, WorkbenchID: row.WorkbenchID.Int64, CreatedAt: start}, nil
}

// SessionWorktrees is db.DB.SessionWorktrees.
func (s DBStore) SessionWorktrees(ctx context.Context, sessionID int64) ([]db.SessionWorktree, error) {
	return s.DB.SessionWorktrees(ctx, sessionID)
}

// SessionTargetBranches is db.DB.SessionTargetBranches.
func (s DBStore) SessionTargetBranches(ctx context.Context, sessionID int64) ([]string, error) {
	return s.DB.SessionTargetBranches(ctx, sessionID)
}

// WorkbenchFolder is the workbench's folder_path.
func (s DBStore) WorkbenchFolder(_ context.Context, workbenchID int64) (string, error) {
	wb, err := s.DB.GetWorkbench(workbenchID)
	if err != nil {
		return "", err
	}
	return wb.FolderPath, nil
}

// WorkbenchFolders is every workbench's folder_path.
func (s DBStore) WorkbenchFolders(context.Context) ([]string, error) {
	wbs, err := s.DB.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(wbs))
	for _, wb := range wbs {
		out = append(out, wb.FolderPath)
	}
	return out, nil
}

// WorkbenchSessionWorktrees is db.DB.WorkbenchSessionWorktrees.
func (s DBStore) WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error) {
	return s.DB.WorkbenchSessionWorktrees(ctx, workbenchID)
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
		out = append(out, SessionActivity{
			ID: r.ID, WorkbenchID: r.WorkbenchID, Title: r.Title, AgentCwd: r.AgentCwd,
			ReportedAt: activityStamp(r.AgentStateAt, now, db.ParseAgentStateStamp),
			LastActive: activityStamp(r.LastActiveAt, now, parseRFC3339),
			Finished:   r.Finished,
		})
	}
	return out, nil
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
