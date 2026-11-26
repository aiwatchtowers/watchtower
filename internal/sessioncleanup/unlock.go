package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/workbenchcheck"
)

// Locked worktrees (#2402 §3). A plan locks its worktrees while it runs and
// nobody unlocks them afterwards, so W3 keeps a locked worktree only until
// its branch is merged with a commit of its own and it has been idle for
// idleFor. Such a worktree is unlocked right before `git worktree remove`,
// after the final re-check, and locked again when the removal fails. The
// old lock is saved first in unlockMarker inside the worktree's admin dir
// (which git deletes with the worktree): a pass killed between the unlock
// and the remove leaves the marker, and every apply turns a marker back
// into the lock before it evaluates anything (restoreLocks).
//
// Writers of the lock: agents and the owner (`git worktree lock|unlock`,
// no lock of ours), and this file, only under the repository cleanup lock
// (every Watchtower cleanup holds it) and, for the unlock and the remove,
// under the worktree lock too. An agent that locks the worktree after the
// final re-check finds it still locked (git refuses a second lock), and one
// that writes into it after the unlock makes git refuse the remove: the
// worktree is locked again, the agent's work stays. Writers of the marker:
// this file alone.

const (
	// unlockMarker holds, byte for byte, the `locked` file of a worktree
	// an apply unlocked for its removal.
	unlockMarker = "watchtower-unlocked"
	// lockFile is git's own lock of a linked worktree, in its admin dir:
	// its reason and a newline, or empty for a lock without one.
	lockFile = "locked"
)

// errUnlockPending keeps a worktree whose marker is still there: an earlier
// apply unlocked it and its lock could not be restored yet.
var errUnlockPending = errors.New("an earlier cleanup unlocked it and could not lock it again yet (" +
	unlockMarker + "); it stays until it is locked again")

// lockState is a worktree's lock as its admin dir holds it now.
type lockState struct {
	locked bool // git's lock (the listing's, or the lock file now)
	marked bool // an unlock of ours not undone yet
}

// readLock reads w's lock from admin ("" = unknown: the listing alone); a
// read that fails is an error (the caller keeps the worktree).
func readLock(w worktree, admin string) (lockState, error) {
	st := lockState{locked: w.Locked}
	if admin == "" {
		return st, nil
	}
	for name, to := range map[string]*bool{lockFile: &st.locked, unlockMarker: &st.marked} {
		_, err := os.Lstat(filepath.Join(admin, name))
		switch {
		case err == nil:
			*to = true
		case !errors.Is(err, fs.ErrNotExist):
			return st, fmt.Errorf("reading the lock of %s: %w", w.Root, err)
		}
	}
	return st, nil
}

// lockedMayGo is W3's exception: the worktree's branch is merged with a
// commit of its own (mergedWithOwnWork) and the worktree has been idle for
// idleFor. Any doubt — no admin dir, a detached HEAD, a failed check — is
// "no".
func (b *builder) lockedMayGo(ctx context.Context, w worktree, admin string) bool {
	return admin != "" && b.mergedWithOwnWork(ctx, w.Branch) && isIdle(ctx, b.deps, w.Root, admin)
}

// mergedWithOwnWork: branch is merged into the default branch by the drift
// check's own detection (workbenchcheck.OpenRepositoryAgainst), under
// which a branch cut from the base with no commit of its own is not
// merged. git runs through the cleanup's runner. A detached HEAD (""), an
// unknown default branch or a verdict git could not reach is not merged.
func (b *builder) mergedWithOwnWork(ctx context.Context, branch string) bool {
	if branch == "" || b.repo.defaultBranch == "" {
		return false
	}
	g := b.repo.git
	run := func(ctx context.Context, dir string, _ []byte, name string, args ...string) ([]byte, int, error) {
		if name != "git" {
			return nil, -1, fmt.Errorf("the cleanup runs git only, not %s", name)
		}
		ctx, cancel := context.WithTimeout(ctx, gitTimeout)
		defer cancel()
		return g.run.RunGit(ctx, dir, g.bin, args...)
	}
	repo := workbenchcheck.OpenRepositoryAgainst(ctx, b.repo.folder, b.repo.defaultBranch, run)
	return repo.BranchMerge(ctx, branch) == workbenchcheck.BranchMerged
}

// restoreLocks turns every unlock marker of the repository at commonDir
// whose worktree still exists back into its lock (relock), before anything
// is evaluated. It returns a note per marker it could not restore; such a
// marker stays and W3 keeps its worktree (errUnlockPending) until a later
// apply restores it. A marker whose worktree is gone is left: git drops its
// admin dir with it.
func restoreLocks(ctx context.Context, g gitCmd, folder, commonDir string) []string {
	base := filepath.Join(commonDir, "worktrees")
	entries, err := os.ReadDir(base)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return []string{fmt.Sprintf("the worktrees' locks could not be checked (%v); unlocked ones stay", err)}
	}
	var notes []string
	for _, e := range entries {
		admin := filepath.Join(base, e.Name())
		if _, err := os.Lstat(filepath.Join(admin, unlockMarker)); errors.Is(err, fs.ErrNotExist) {
			continue
		}
		root, ok := adminRoot(admin)
		if !ok {
			continue
		}
		if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
			continue
		}
		if err := relock(ctx, g, folder, admin, root); err != nil {
			notes = append(notes, err.Error())
		}
	}
	return notes
}

// relock undoes an unlock of ours: when root is not locked now, `git
// worktree lock` with the reason the marker saved; then the marker goes.
// A worktree locked meanwhile (killed before the unlock, or locked by an
// agent since) keeps that lock. The lock runs even when ctx is done (a
// stopping daemon), within gitTimeout. On failure the marker stays.
func relock(ctx context.Context, g gitCmd, folder, admin, root string) error {
	marker := filepath.Join(admin, unlockMarker)
	saved, err := os.ReadFile(marker)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return fmt.Errorf("reading %s: %w", marker, err)
	}
	locked, err := isLocked(admin)
	if err != nil {
		return err
	}
	if !locked {
		args := []string{"worktree", "lock"}
		if reason := strings.TrimSuffix(string(saved), "\n"); reason != "" {
			args = append(args, "--reason", reason)
		}
		lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), gitTimeout)
		_, _, err := g.run.RunGit(lctx, folder, g.bin, append(args, root)...)
		cancel()
		if err != nil {
			if now, lerr := isLocked(admin); lerr != nil || !now {
				return fmt.Errorf("locking %s again: %w", root, err)
			}
		}
	}
	if err := os.Remove(marker); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("deleting %s: %w", marker, err)
	}
	return nil
}

func isLocked(admin string) (bool, error) {
	_, err := os.Lstat(filepath.Join(admin, lockFile))
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, fs.ErrNotExist):
		return false, nil
	}
	return false, fmt.Errorf("reading the lock in %s: %w", admin, err)
}

// unlockForRemoval unlocks root, when it is locked now, for the removal
// that follows at once: the lock file is saved in the marker (written and
// synced first), then `git worktree unlock`. true when it unlocked (the
// caller relocks if the removal fails). A failure leaves the worktree
// locked as it was (relock) and is returned: the worktree stays.
func (a *applier) unlockForRemoval(ctx context.Context, root, admin string) (bool, error) {
	if admin == "" {
		return false, nil // W3 let it pass only unlocked; git refuses a locked one
	}
	body, err := os.ReadFile(filepath.Join(admin, lockFile))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return false, nil
	case err != nil:
		return false, fmt.Errorf("reading the lock of %s: %w", root, err)
	}
	if err := writeMarker(filepath.Join(admin, unlockMarker), body); err != nil {
		return false, fmt.Errorf("saving the lock of %s: %w", root, err)
	}
	uctx, cancel := context.WithTimeout(ctx, gitTimeout)
	_, _, err = a.git.run.RunGit(uctx, a.folder, a.git.bin, "worktree", "unlock", root)
	cancel()
	if err != nil {
		if rerr := relock(ctx, a.git, a.folder, admin, root); rerr != nil {
			return false, fmt.Errorf("unlocking %s: %w; restoring its lock failed, the next cleanup retries: %v",
				root, err, rerr)
		}
		return false, fmt.Errorf("unlocking %s: %w", root, err)
	}
	return true, nil
}

// writeMarker creates path (never over an existing one) holding body,
// synced before it returns.
func writeMarker(path string, body []byte) (err error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err //nolint:wrapcheck // the caller names the worktree
	}
	defer func() {
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			_ = os.Remove(path) // ours, just made: nothing was unlocked yet
		}
	}()
	if _, err = f.Write(body); err != nil {
		return err //nolint:wrapcheck // the caller names the worktree
	}
	return f.Sync() //nolint:wrapcheck // the caller names the worktree
}

// removeWorktreeNow runs `git worktree remove` (no --force) on root right
// after the final re-check. A worktree locked now — W3 let it pass: merged
// and idle — is unlocked first (unlockForRemoval) and locked again when
// the removal fails; it is then kept as check_failed, and a failure that is
// not git's own refusal stops the apply, as settleGit does.
func (a *applier) removeWorktreeNow(ctx context.Context, it *Item, root, admin string) {
	unlocked, err := a.unlockForRemoval(ctx, root, admin)
	if err != nil {
		keepItem(it, ReasonCheckFailed, err.Error())
		return
	}
	rctx, cancel := context.WithTimeout(ctx, worktreeRemoveTimeout)
	_, code, err := a.git.run.RunGit(rctx, a.folder, a.git.bin, "worktree", "remove", root)
	cancel()
	if !unlocked || err == nil {
		a.settleGit(it, code, err)
		return
	}
	detail := fmt.Sprintf("removing it failed (%v); locked again", err)
	if rerr := relock(ctx, a.git, a.folder, admin, root); rerr != nil {
		detail = fmt.Sprintf("removing it failed (%v); locking it again failed, the next cleanup retries: %v", err, rerr)
	}
	keepItem(it, ReasonCheckFailed, detail)
	var gitErr *GitError
	if code <= 0 || !errors.As(err, &gitErr) {
		a.halt = err
	}
}
