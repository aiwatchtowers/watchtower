package memory

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"

	"watchtower/internal/db"
)

// This file is the operator recovery path for a vault whose recent history is
// wrong: it rewinds the vault to a known-good commit and rebuilds the index
// from the files it leaves behind. It exists because the alternative is a
// hand-typed `git reset --hard` on the owner's only copy of the memory —
// unpreviewable, unrepeatable, and one typo away from discarding history that
// was fine. Everything here is therefore plan-then-apply: PlanReset reads and
// reports, ResetTo is the only function that writes.

// dirtySampleCap bounds how many uncommitted paths a plan carries, so a vault
// full of unstaged edits still reports a readable refusal.
const dirtySampleCap = 10

// ResetPlan is what `memory reset-to <commit>` would do, computed without
// writing anything: where HEAD is now, where it would land, and what the reset
// would throw away.
type ResetPlan struct {
	Head           string // hex hash of the current HEAD commit
	Target         string // hex hash of the resolved target commit
	CommitsDropped int    // commits reachable from HEAD but not from the target
	FilesRemoved   int    // tracked files present at HEAD and absent at the target
	Dirty          []string
	DirtyCount     int // uncommitted worktree paths; Dirty carries the first dirtySampleCap
}

// PlanReset resolves ref against the vault repository and reports what a hard
// reset to it would discard. It writes nothing — not to the vault, not to the
// index — so it is also what `--dry-run` prints.
//
// ref must be an ancestor of HEAD: this command rewinds the vault's own
// history, it does not move it onto an unrelated commit. A revision that does
// not resolve, does not name a commit, or is not an ancestor is refused here,
// before ResetTo can be called with it.
func PlanReset(v *Vault, ref string) (ResetPlan, error) {
	headRef, err := v.repo.Head()
	if err != nil {
		return ResetPlan{}, fmt.Errorf("memory: reset: reading vault HEAD: %w", err)
	}
	head, err := v.repo.CommitObject(headRef.Hash())
	if err != nil {
		return ResetPlan{}, fmt.Errorf("memory: reset: reading HEAD commit %s: %w", headRef.Hash(), err)
	}
	hash, err := v.repo.ResolveRevision(plumbing.Revision(ref))
	if err != nil {
		return ResetPlan{}, fmt.Errorf("memory: reset: commit %q not found in the vault repository: %w", ref, err)
	}
	target, err := v.repo.CommitObject(*hash)
	if err != nil {
		return ResetPlan{}, fmt.Errorf("memory: reset: %q (%s) is not a commit: %w", ref, hash, err)
	}
	ancestor, err := target.IsAncestor(head)
	if err != nil {
		return ResetPlan{}, fmt.Errorf("memory: reset: checking whether %s is an ancestor of HEAD: %w", target.Hash, err)
	}
	if !ancestor {
		return ResetPlan{}, fmt.Errorf("memory: reset: %s is not an ancestor of HEAD %s — refusing to move the vault onto unrelated history",
			target.Hash, head.Hash)
	}

	dropped, err := countCommitsUntil(v.repo, head.Hash, target.Hash)
	if err != nil {
		return ResetPlan{}, err
	}
	removed, err := countFilesRemoved(head, target)
	if err != nil {
		return ResetPlan{}, err
	}
	dirty, dirtyCount, err := worktreeDirt(v)
	if err != nil {
		return ResetPlan{}, err
	}
	return ResetPlan{
		Head:           head.Hash.String(),
		Target:         target.Hash.String(),
		CommitsDropped: dropped,
		FilesRemoved:   removed,
		Dirty:          dirty,
		DirtyCount:     dirtyCount,
	}, nil
}

// ResetTo hard-resets the vault worktree and HEAD to plan.Target and rebuilds
// the SQLite index from the files that survive (MEM-02: the index is derived,
// so rewinding the files is the whole of the recovery — the index follows).
// It reuses Rebuild, the same DropMemoryIndex + Reconcile path
// `watchtower memory reindex` runs.
//
// A dirty worktree refuses the reset: a hard reset discards uncommitted
// changes, and an uncommitted change in the vault is an owner edit the
// pipeline has not committed yet (MEM-03). The caller commits or removes it
// and re-plans.
//
// The caller must hold the vault lock. Any failure after the reset itself says
// so in the error: the files are already rewound, only the index is stale, and
// `watchtower memory reindex` finishes the job.
func ResetTo(v *Vault, database *db.DB, plan ResetPlan, logf func(string, ...any)) (Stats, error) {
	if plan.DirtyCount > 0 {
		return Stats{}, fmt.Errorf("memory: reset: the vault worktree has %d uncommitted change(s) (%s) — "+
			"a hard reset would discard them; commit or remove them first",
			plan.DirtyCount, strings.Join(plan.Dirty, ", "))
	}
	if plan.Target == "" {
		return Stats{}, fmt.Errorf("memory: reset: plan carries no target commit")
	}
	wt, err := v.repo.Worktree()
	if err != nil {
		return Stats{}, fmt.Errorf("memory: reset: vault worktree: %w", err)
	}
	if err := wt.Reset(&git.ResetOptions{Commit: plumbing.NewHash(plan.Target), Mode: git.HardReset}); err != nil {
		return Stats{}, fmt.Errorf("memory: reset: hard reset to %s: %w", plan.Target, err)
	}
	// git tracks no empty directories, so a reset that removed every file of a
	// node directory can leave the directory itself gone — which Reconcile's
	// ReadDir would fail on.
	if err := ensureSubdirs(v.path); err != nil {
		return Stats{}, fmt.Errorf("%w (the vault is reset to %s; run `watchtower memory reindex` to rebuild the index)", err, plan.Target)
	}

	stats, err := Rebuild(v, database, logf)
	if err != nil {
		return stats, fmt.Errorf("%w (the vault is reset to %s but the index is stale; run `watchtower memory reindex`)", err, plan.Target)
	}
	return stats, nil
}

// countCommitsUntil counts the commits walked from `from` before reaching
// `target`. The vault history is linear (single author, no merges — the same
// invariant LogMemoryCommits relies on), so this is exactly the number of
// commits the reset discards.
func countCommitsUntil(repo *git.Repository, from, target plumbing.Hash) (int, error) {
	iter, err := repo.Log(&git.LogOptions{From: from})
	if err != nil {
		return 0, fmt.Errorf("memory: reset: reading vault log: %w", err)
	}
	defer iter.Close()

	count, found := 0, false
	err = iter.ForEach(func(c *object.Commit) error {
		if c.Hash == target {
			found = true
			return storer.ErrStop
		}
		count++
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("memory: reset: walking vault log: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("memory: reset: %s is not reachable from %s", target, from)
	}
	return count, nil
}

// countFilesRemoved counts the tracked files that exist at head and not at
// target — the files the reset deletes from the worktree.
func countFilesRemoved(head, target *object.Commit) (int, error) {
	headTree, err := head.Tree()
	if err != nil {
		return 0, fmt.Errorf("memory: reset: reading HEAD tree: %w", err)
	}
	targetTree, err := target.Tree()
	if err != nil {
		return 0, fmt.Errorf("memory: reset: reading target tree: %w", err)
	}
	headPaths, err := treePaths(headTree)
	if err != nil {
		return 0, err
	}
	targetPaths, err := treePaths(targetTree)
	if err != nil {
		return 0, err
	}
	removed := 0
	for p := range headPaths {
		if !targetPaths[p] {
			removed++
		}
	}
	return removed, nil
}

// treePaths lists the file paths of a commit tree. It walks entries only —
// never blob contents — because a duplicate-ridden vault carries tens of
// thousands of files and the plan needs their names, not their bytes.
func treePaths(t *object.Tree) (map[string]bool, error) {
	w := object.NewTreeWalker(t, true, nil)
	defer w.Close()

	out := make(map[string]bool)
	for {
		name, entry, err := w.Next()
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, fmt.Errorf("memory: reset: walking vault tree: %w", err)
		}
		if entry.Mode.IsFile() {
			out[name] = true
		}
	}
}

// worktreeDirt returns the uncommitted worktree paths (sorted, sampled to
// dirtySampleCap) and their total count.
func worktreeDirt(v *Vault) ([]string, int, error) {
	wt, err := v.repo.Worktree()
	if err != nil {
		return nil, 0, fmt.Errorf("memory: reset: vault worktree: %w", err)
	}
	status, err := wt.Status()
	if err != nil {
		return nil, 0, fmt.Errorf("memory: reset: vault status: %w", err)
	}
	var paths []string
	for p, s := range status {
		if s.Staging == git.Unmodified && s.Worktree == git.Unmodified {
			continue
		}
		paths = append(paths, p)
	}
	sort.Strings(paths)
	total := len(paths)
	if len(paths) > dirtySampleCap {
		paths = paths[:dirtySampleCap]
	}
	return paths, total, nil
}
