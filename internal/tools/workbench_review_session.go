package tools

import (
	"context"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
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

// ReviewSource is what a session's review round reads (board #1012, ask
// #543: "the folder when it is on the task's branch, else the branch
// itself").
type ReviewSource struct {
	// Folder is the session's review folder (ReviewSessionFolder); git runs there.
	Folder string
	// Tip, when set, is the task branch the round reviews at its committed
	// tip, read-only: the folder is not checked out on it.
	Tip *reviewdiff.BranchTip
	// BaseBranch is the branch above the task branch the tip is measured
	// against; "" = the default branch.
	BaseBranch string
}

// Source is the review_rounds.source value of the place.
func (s ReviewSource) Source() string {
	if s.Tip != nil {
		return db.ReviewSourceBranch
	}
	return db.ReviewSourceFolder
}

// Read is the place's tree and base: the folder's snapshot against the
// default branch, or the branch tip against its base branch.
func (s ReviewSource) Read(ctx context.Context, repo *reviewdiff.Repo) (tree string, base reviewdiff.Base, err error) {
	if s.Tip != nil {
		base, err = repo.BranchBase(ctx, *s.Tip, s.BaseBranch)
		return s.Tip.Tree, base, err
	}
	if tree, err = repo.Snapshot(ctx); err != nil {
		return "", reviewdiff.Base{}, err
	}
	base, err = repo.Base(ctx)
	return tree, base, err
}

// ResolveReviewSource finds session sessionID's review place: its folder,
// unless the session's target (terminal_sessions.target_id) or its nearest
// ancestor carrying one names a task branch, the folder is checked out on
// another branch (or detached), and that branch exists locally or on
// origin — then the branch's tip. A task branch found nowhere falls back to
// the folder.
func ResolveReviewSource(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (ReviewSource, *reviewdiff.Repo, error) {
	folder, err := ReviewSessionFolder(ctx, d, p, sessionID)
	if err != nil {
		return ReviewSource{}, nil, err
	}
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return ReviewSource{}, nil, err
	}
	src := ReviewSource{Folder: folder}
	ticket, err := d.SessionTicket(sessionID)
	if err != nil || ticket == 0 {
		return src, repo, err
	}
	chain, err := d.TicketBranchChain(p.ID, ticket)
	if err != nil {
		return ReviewSource{}, nil, err
	}
	branch, base := TaskBranch(chain)
	if branch == "" {
		return src, repo, nil
	}
	head, err := repo.HeadBranch(ctx)
	if err != nil || head == branch {
		return src, repo, err
	}
	tip, ok, err := repo.Branch(ctx, branch)
	if err != nil || !ok {
		return src, repo, err
	}
	src.Tip, src.BaseBranch = &tip, base
	return src, repo, nil
}

// TaskBranch reads a target's branch chain (the target first, then each
// ancestor, as db.TicketBranchChain lists it): the task branch is the first
// non-empty one; its base is the next one above it that differs ("" = the
// default branch) — the nearest-branch-carrying-ancestor rule of board
// #986's merged share.
func TaskBranch(chain []string) (branch, base string) {
	for _, b := range chain {
		if b == "" {
			continue
		}
		if branch == "" {
			branch = b
			continue
		}
		if b != branch {
			return branch, b
		}
	}
	return branch, ""
}
