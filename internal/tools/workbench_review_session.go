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
	folder, _, err := reviewSessionPlace(ctx, d, p, sessionID)
	return folder, err
}

// reviewSessionPlace is ReviewSessionFolder plus whether the agent's folder
// no longer exists (a worktree removed by the #535 cleanup): the folder is
// then the workbench folder.
func reviewSessionPlace(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (folder string, missing bool, err error) {
	if err := CheckSessionOnWorkbench(d, p, sessionID); err != nil {
		return "", false, err
	}
	cwd, err := d.TerminalAgentCwd(sessionID)
	if err != nil {
		return "", false, err
	}
	resolved, err := workbenchgit.ResolveFolder(ctx, workbenchgit.Options{Folder: p.FolderPath}, cwd.Path)
	if err != nil {
		return "", false, err
	}
	missing = resolved.Scope == workbenchgit.ScopeMissing
	if resolved.Root == "" {
		return p.FolderPath, missing, nil
	}
	return resolved.Root, missing, nil
}

// ReviewSource is what a session's review round reads (board #1012, ask
// #543: "the folder when it is on the task's branch, else the branch
// itself" — the "else" scoped to the folder sitting on the default branch
// or a detached HEAD, the situation the question described).
type ReviewSource struct {
	// Folder is the session's review folder (ReviewSessionFolder); git runs there.
	Folder string
	// FolderMissing: the agent's folder no longer exists (a removed
	// worktree); Folder is the workbench folder. An open round is not moved
	// there: the place is gone, not changed.
	FolderMissing bool
	// Tip, when set, is the task branch the round reviews at its committed
	// tip, read-only: the folder is on the default branch or detached.
	Tip *reviewdiff.BranchTip
	// BaseBranch is the branch above the task branch the round is measured
	// against, for a tip and for a folder checked out on the task branch
	// alike; "" = the default branch.
	BaseBranch string
}

// Source is the review_rounds.source value of the place.
func (s ReviewSource) Source() string {
	if s.Tip != nil {
		return db.ReviewSourceBranch
	}
	return db.ReviewSourceFolder
}

// Branch is the review_rounds.branch value of the place: the tip's branch,
// "" for a folder.
func (s ReviewSource) Branch() string {
	if s.Tip != nil {
		return s.Tip.Name
	}
	return ""
}

// Read is the place's tree and base: the folder's snapshot or the branch
// tip, each against BaseBranch, else the default branch.
func (s ReviewSource) Read(ctx context.Context, repo *reviewdiff.Repo) (tree string, base reviewdiff.Base, err error) {
	if s.Tip != nil {
		base, err = repo.BranchBase(ctx, *s.Tip, s.BaseBranch)
		return s.Tip.Tree, base, err
	}
	if tree, err = repo.Snapshot(ctx); err != nil {
		return "", reviewdiff.Base{}, err
	}
	base, err = repo.HeadBase(ctx, s.BaseBranch)
	return tree, base, err
}

// Head is the commit the place's snapshot stands on (review_rounds.head_sha,
// the big-branch map's lane walk): the tip's commit, else the folder's HEAD
// ("" when HEAD is unborn), read through repo's hardened runner (REVIEW-05).
func (s ReviewSource) Head(ctx context.Context, repo *reviewdiff.Repo) (string, error) {
	if s.Tip != nil {
		return s.Tip.Commit, nil
	}
	return repo.HeadCommit(ctx)
}

// ResolveReviewSource finds session sessionID's review place. The session's
// target (terminal_sessions.target_id), or its nearest ancestor carrying
// one, may name a task branch:
//   - the folder is checked out on it → the folder, measured against the
//     branch above it (as the tip would be);
//   - the folder is on the default branch (as reviewdiff.Base finds it) or
//     detached, and the branch exists locally or on origin → its tip;
//   - any other branch (a Watchtower wt/<slug> worktree, the owner's own
//     branch) or a task branch found nowhere → the folder, as before.
func ResolveReviewSource(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64) (ReviewSource, *reviewdiff.Repo, error) {
	folder, missing, err := reviewSessionPlace(ctx, d, p, sessionID)
	if err != nil {
		return ReviewSource{}, nil, fmt.Errorf("resolving session %d's folder: %w", sessionID, err)
	}
	src, repo, err := ReviewSourceIn(ctx, d, p, sessionID, folder)
	src.FolderMissing = missing
	return src, repo, err
}

// ReviewSourceIn is ResolveReviewSource with the session's folder given:
// the caller keeps an open round in a folder that still exists when the
// agent's last directory inside it is gone (a deleted subfolder).
func ReviewSourceIn(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64, folder string) (ReviewSource, *reviewdiff.Repo, error) {
	repo, err := reviewdiff.Open(folder, nil)
	if err != nil {
		return ReviewSource{}, nil, fmt.Errorf("opening session %d's folder: %w", sessionID, err)
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
	if err != nil {
		return ReviewSource{}, nil, fmt.Errorf("reading session %d's checked-out branch: %w", sessionID, err)
	}
	if head == branch {
		src.BaseBranch = base
		return src, repo, nil
	}
	if head != "" {
		def, err := repo.DefaultBranch(ctx)
		if err != nil {
			return ReviewSource{}, nil, fmt.Errorf("reading the default branch: %w", err)
		}
		if head != def {
			return src, repo, nil
		}
	}
	tip, ok, err := repo.Branch(ctx, branch)
	if err != nil {
		return ReviewSource{}, nil, fmt.Errorf("reading task branch %q: %w", branch, err)
	}
	if !ok {
		return src, repo, nil
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
