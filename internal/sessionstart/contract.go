package sessionstart

import (
	"context"
	"path/filepath"
	"strconv"
	"time"

	"watchtower/internal/fsutil"
)

// The Desktop's side of a start (Go hub 3 Task 8) reads these; the Swift
// twin is GoSessionStartContract, both pinned by testdata/desktop_contract.json.
const (
	// MoveFailedPrefix starts agent_error when the row could not be moved
	// into the worktree made for it: the Desktop reports it on the page,
	// deletes the never-run row and drops it from the layout, as before.
	MoveFailedPrefix = "Could not move the session into its worktree: "
	// SetupNotRunPrefix starts the start_notice line of a placed row whose
	// first launch did not run, so its setup command never ran.
	SetupNotRunPrefix = "The worktree setup command did not run — run it in the terminal: "
	// LockTimeoutReason is agent_error when another start of the workbench
	// held the placement lock past placementLockWait (within agent_error's
	// 60-rune clip).
	LockTimeoutReason = "another start of this workbench is still placing"
	// AgentNotFoundExit and AgentNotFoundClass are `workbench session start`'s
	// answer when the agent's binary is missing: this exit code and
	// {"error": AgentNotFoundClass, "agent": …} on stdout.
	AgentNotFoundExit  = 3
	AgentNotFoundClass = "agent_not_found"
)

// placementLockWait bounds the wait for another process's placement of the
// same workbench (inside finishBudget); a test seam.
var placementLockWait = 60 * time.Second

// PlacementLockPath is the per-workbench placement lock beside the database:
// every start of the workbench — Go's finish, the Desktop's own launch path —
// holds it from deciding the place until the run is in the session host, so
// two starts in two processes never both find the folder free.
func PlacementLockPath(dbPath string, workbench int64) string {
	return filepath.Join(filepath.Dir(dbPath), "workbench-"+strconv.FormatInt(workbench, 10)+".place.lock")
}

// AgentNotFoundReason is agent_error when the agent's binary is missing.
func AgentNotFoundReason(agent string) string { return agent + " was not found" }

// lockPlacement takes the workbench's placement lock, waiting at most
// placementLockWait; without a database path there is nothing to share it
// with and it locks nothing.
func (s *newStart) lockPlacement(ctx context.Context) (func(), error) {
	if s.d.DBPath == "" {
		return func() {}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, placementLockWait)
	defer cancel()
	return fsutil.LockFile(ctx, PlacementLockPath(s.d.DBPath, s.wb.id)) //nolint:wrapcheck // LockFile names the file
}
