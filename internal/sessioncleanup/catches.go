package sessioncleanup

import (
	"context"
	"fmt"
	"path/filepath"
	"time"
)

// Catch reasons (spec §5, §6, §9). The ownership reasons are in ownership.go.
const (
	ReasonMainFolder         = "main_folder"
	ReasonWorkbenchFolder    = "workbench_folder"
	ReasonLocked             = "locked"
	ReasonUncommittedChanges = "uncommitted_changes"
	ReasonProcessRunning     = "process_running"
	// ReasonProcessUnknown: a process of the current user whose cwd the
	// scan could not see; it may be working inside, so the worktree stays.
	ReasonProcessUnknown      = "process_unknown"
	ReasonSessionInIt         = "session_in_it"
	ReasonYouAreInIt          = "you_are_in_it"
	ReasonUnpushedCommits     = "unpushed_commits"
	ReasonOperationInProgress = "operation_in_progress"
	ReasonDefaultBranch       = "default_branch"
	// ReasonDefaultBranchUnknown: no origin/HEAD, main or master (or git
	// failed reading origin/HEAD); every branch is kept.
	ReasonDefaultBranchUnknown = "default_branch_unknown"
	ReasonCheckedOut           = "checked_out"
	// ReasonClaudeHome: the worktree is under the owner's ~/.claude.
	ReasonClaudeHome    = "claude_home"
	ReasonNotAWorktree  = "not_a_worktree"
	ReasonNotABranch    = "not_a_branch"
	ReasonSessionRecent = "session_recent"
	// ReasonCheckFailed: a catch could not be evaluated (git or a file read
	// failed); the item is kept with the error in detail.
	ReasonCheckFailed = "check_failed"
	// ReasonContainsWorktree: another worktree or repository lies inside;
	// its path is in detail.
	ReasonContainsWorktree = "contains_worktree"
)

// Windows of the in-use catches: another session counts as in a worktree
// when it reported within inUseWindow (W6); the sweep keeps an item whose
// owner session was active within recentOwnerWindow.
const (
	inUseWindow       = 24 * time.Hour
	recentOwnerWindow = 7 * 24 * time.Hour
)

// nestedScanBudget bounds W9's walk of one worktree; over it the worktree
// is kept (check_failed).
const nestedScanBudget = 20 * time.Second

// worktreeCatch returns the reason a worktree is kept, "" to let it pass.
type worktreeCatch func(ctx context.Context, b *builder, w worktree) (reason, detail string, err error)

// worktreeCatches is W1–W9 in order (spec §5); the sweep swaps W2 for the
// recent-owner rule, and a prunable worktree (its directory is gone) meets
// the folder, ownership and unpushed catches: pruning drops its HEAD, which
// may be the only ref to its commits.
func (b *builder) worktreeCatches(w worktree) []worktreeCatch {
	own := catchOwnWorktree
	if b.req.Sweep {
		own = catchRecentOwner
	}
	if w.Prunable {
		return []worktreeCatch{catchClaudeHome, catchFolders, own, catchUnpushed}
	}
	return []worktreeCatch{catchClaudeHome, catchFolders, own, catchLocked, catchUncommitted, catchProcesses,
		catchSessionInIt, catchUnpushed, catchOperation, catchNested}
}

// catchClaudeHome keeps anything under the owner's ~/.claude, and every
// worktree when the home directory is unknown.
func catchClaudeHome(_ context.Context, b *builder, w worktree) (string, string, error) {
	if b.homeErr != nil {
		return "", "", fmt.Errorf("locating the home directory: %w", b.homeErr)
	}
	for _, dir := range b.claudeHome {
		if pathWithin(w.Root, dir) {
			return ReasonClaudeHome, dir, nil
		}
	}
	return "", "", nil
}

// catchFolders is W1: the main worktree, a workbench folder or a worktree
// holding one.
func catchFolders(_ context.Context, b *builder, w worktree) (string, string, error) {
	if w.Main {
		return ReasonMainFolder, "", nil
	}
	for _, f := range b.folders {
		if pathWithin(f, w.Root) {
			return ReasonWorkbenchFolder, f, nil
		}
	}
	return "", "", nil
}

// catchOwnWorktree is W2: observed by the session and born after it, or
// the placed row's own worktree (owned by record, spec 2026-10-14 §9).
func catchOwnWorktree(_ context.Context, b *builder, w worktree) (string, string, error) {
	if b.seen.placedRoot != "" && w.Root == b.seen.placedRoot {
		return "", "", nil
	}
	if !b.seen.sawWorktree(w) {
		return ReasonNotThisSession, "", nil
	}
	birth, known := b.worktreeBirth(w.Root)
	return bornReason(birth, known, b.session.CreatedAt), "", nil
}

// worktreeBirth is the birth of root's admin dir through Deps.WorktreeBirth
// (the platform's when nil).
func (b *builder) worktreeBirth(root string) (time.Time, bool) {
	birthOf := birthTime
	if b.deps.WorktreeBirth != nil {
		birthOf = b.deps.WorktreeBirth
	}
	return b.repo.worktreeBirth(root, birthOf)
}

// catchRecentOwner is the sweep's W2: a session that recorded the worktree
// is live or was active within recentOwnerWindow and is not finished.
func catchRecentOwner(_ context.Context, b *builder, w worktree) (string, string, error) {
	for _, id := range b.rootOwners[w.Root] {
		if a, ok := b.activity[id]; ok && b.recentlyActive(a) {
			return ReasonSessionRecent, a.Title, nil
		}
	}
	return "", "", nil
}

func (b *builder) recentlyActive(a SessionActivity) bool {
	if b.live[a.ID] {
		return true
	}
	last := a.ReportedAt
	if a.LastActive.After(last) {
		last = a.LastActive
	}
	return !a.Finished && !last.IsZero() && b.now.Sub(last) <= recentOwnerWindow
}

// catchLocked is W3.
func catchLocked(_ context.Context, _ *builder, w worktree) (string, string, error) {
	if w.Locked {
		return ReasonLocked, "", nil
	}
	return "", "", nil
}

// catchUncommitted is W4.
func catchUncommitted(ctx context.Context, b *builder, w worktree) (string, string, error) {
	dirty, err := b.repo.isDirty(ctx, w.Root)
	if err != nil || !dirty {
		return "", "", err
	}
	return ReasonUncommittedChanges, "", nil
}

// catchProcesses is W5: a process inside that is not an orphan of this
// session. The sweep never terminates, so an orphan blocks it too.
func catchProcesses(_ context.Context, b *builder, w worktree) (string, string, error) {
	orphans, blockers := OrphansIn(b.procs, []string{w.Root}, b.self)
	if b.req.Sweep {
		blockers = append(blockers, orphans...)
	}
	if len(blockers) == 0 {
		return "", "", nil
	}
	p := blockers[0]
	detail := fmt.Sprintf("process in use: %s pid %d", procLabel(p), p.PID)
	if ProcUnknown(p) {
		return ReasonProcessUnknown, detail, nil
	}
	return ReasonProcessRunning, detail, nil
}

// procLabel names p for a message: its executable's base name, else ps's
// comm, else "unknown".
func procLabel(p Proc) string {
	for _, name := range []string{p.Exe, p.Name} {
		if name != "" {
			return filepath.Base(name)
		}
	}
	return "unknown"
}

// catchSessionInIt is W6: the caller works inside, or another session whose
// agent works inside is live or reported within inUseWindow and is not
// finished.
func catchSessionInIt(_ context.Context, b *builder, w worktree) (string, string, error) {
	reason, detail := "", ""
	for _, a := range b.activity {
		if !pathWithin(a.AgentCwd, w.Root) {
			continue
		}
		if b.req.CallerSessionID != 0 && a.ID == b.req.CallerSessionID {
			return ReasonYouAreInIt, "", nil
		}
		if b.live[a.ID] || (!a.Finished && !a.ReportedAt.IsZero() && b.now.Sub(a.ReportedAt) <= inUseWindow) {
			reason, detail = ReasonSessionInIt, a.Title
		}
	}
	return reason, detail, nil
}

// catchUnpushed is W7: HEAD in neither the default branch nor a remote ref.
func catchUnpushed(ctx context.Context, b *builder, w worktree) (string, string, error) {
	head, err := b.repo.recordedHead(w)
	if err != nil {
		return "", "", err
	}
	in, err := b.repo.isContained(ctx, head)
	if err != nil || in {
		return "", "", err
	}
	return ReasonUnpushedCommits, "", nil
}

// catchOperation is W8.
func catchOperation(_ context.Context, b *builder, w worktree) (string, string, error) {
	marker, err := b.repo.operationIn(w.Root)
	if err != nil || marker == "" {
		return "", "", err
	}
	return ReasonOperationInProgress, marker, nil
}

// catchNested is W9: another listed worktree, or any `.git` file or
// directory but the worktree's own, inside it. `git worktree remove`
// deletes the whole directory, ignored files included, so a worktree or
// repository nested under an ignored directory would go with its own
// uncommitted work.
func catchNested(ctx context.Context, b *builder, w worktree) (string, string, error) {
	for _, o := range b.repo.worktrees {
		if o.Root != w.Root && pathWithin(o.Root, w.Root) {
			return ReasonContainsWorktree, o.Root, nil
		}
	}
	nested, err := b.nestedIn(ctx, w.Root)
	if err != nil || nested == "" {
		return "", "", err
	}
	return ReasonContainsWorktree, nested, nil
}

// nestedIn is W9's walk of root, served from b.walked when it has root; a
// failed walk is not cached.
func (b *builder) nestedIn(ctx context.Context, root string) (string, error) {
	if nested, ok := b.walked[root]; ok {
		return nested, nil
	}
	nested, err := findNestedRepository(ctx, root, nestedScanBudget)
	if err == nil && b.walked != nil {
		b.walked[root] = nested
	}
	return nested, err
}

// branchCatch returns the reason a branch is kept, "" to let it pass.
type branchCatch func(ctx context.Context, b *builder, br branchRef) (reason, detail string, err error)

// branchCatches is B1–B4 in order; the sweep swaps B3 for the
// recent-owner rule.
func (b *builder) branchCatches() []branchCatch {
	own := catchOwnBranch
	if b.req.Sweep {
		own = catchBranchRecentOwner
	}
	return []branchCatch{catchDefaultBranch, catchCheckedOut, own, catchBranchUnpushed}
}

// catchDefaultBranch is B1; an unknown default branch keeps every branch.
func catchDefaultBranch(_ context.Context, b *builder, br branchRef) (string, string, error) {
	if b.repo.defaultBranch == "" {
		// The lookup error is reported as the keep detail, not returned:
		// an unknown default branch keeps the branch rather than failing.
		detail := ""
		if b.repo.defaultErr != nil {
			detail = b.repo.defaultErr.Error()
		}
		return ReasonDefaultBranchUnknown, detail, nil
	}
	if br.Name == b.repo.defaultBranch {
		return ReasonDefaultBranch, "", nil
	}
	return "", "", nil
}

// catchCheckedOut is B2: checked out in a worktree that stays.
func catchCheckedOut(_ context.Context, b *builder, br branchRef) (string, string, error) {
	if root, ok := b.checkedOutStaying[br.Name]; ok {
		return ReasonCheckedOut, root, nil
	}
	return "", "", nil
}

// catchOwnBranch is B3: observed by the session and born after it, or the
// placed row's own worktree_branch (owned by record, spec 2026-10-14 §9).
func catchOwnBranch(_ context.Context, b *builder, br branchRef) (string, string, error) {
	if b.seen.placedBranch != "" && br.Name == b.seen.placedBranch { // observePlacement set it only when born no later than the row
		return "", "", nil
	}
	if !b.seen.branches[br.Name] {
		return ReasonNotThisSession, "", nil
	}
	birth, known := b.repo.branchBirth(br.Name)
	return bornReason(birth, known, b.session.CreatedAt), "", nil
}

// catchBranchRecentOwner is the sweep's B3: the owner of the worktree the
// branch is checked out in is recent.
func catchBranchRecentOwner(ctx context.Context, b *builder, br branchRef) (string, string, error) {
	if root, ok := b.checkedOutIn[br.Name]; ok {
		return catchRecentOwner(ctx, b, worktree{Root: root})
	}
	return "", "", nil
}

// catchBranchUnpushed is B4.
func catchBranchUnpushed(ctx context.Context, b *builder, br branchRef) (string, string, error) {
	in, err := b.repo.isContained(ctx, br.Sha)
	if err != nil || in {
		return "", "", err
	}
	return ReasonUnpushedCommits, "", nil
}
