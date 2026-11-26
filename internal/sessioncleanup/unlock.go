package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

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
	locked bool     // git's lock (the listing's, or the lock file now)
	marked bool     // an unlock of ours not undone yet
	seen   lockSeen // the lock file as read
}

// lockSeen is one reading of a worktree's lock file: whether it exists,
// its content and its mtime. A lock dropped and taken again reads
// differently (a new file), even with the same reason, unless both land in
// one mtime tick with the same reason.
type lockSeen struct {
	exists bool
	body   string
	mod    time.Time
	fi     fs.FileInfo // the file itself: a new lock is a new file (os.SameFile)
}

func (s lockSeen) same(o lockSeen) bool {
	return s.exists == o.exists && s.body == o.body && s.mod.Equal(o.mod) &&
		(!s.exists || os.SameFile(s.fi, o.fi))
}

// readLockFile reads admin's lock file; a read that fails is an error.
func readLockFile(admin string) (lockSeen, error) {
	path := filepath.Join(admin, lockFile)
	body, fi, err := readSmallFile(path, smallFileMax)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return lockSeen{}, nil
	case err != nil:
		return lockSeen{}, fmt.Errorf("reading %s: %w", path, err)
	}
	return lockSeen{exists: true, body: string(body), mod: fi.ModTime(), fi: fi}, nil
}

// smallFileMax bounds a lock file or unlock marker this file reads.
const smallFileMax = 64 << 10

// errNotSmallRegular: the entry is not a regular file of at most the size
// asked for (a FIFO, a device, a symlink, a directory, a huge file).
var errNotSmallRegular = errors.New("not a small regular file")

// readSmallFile reads path only when it is a regular file of at most max
// bytes (fix round 4, R4-1): Lstat first, then an open that follows no
// symlink and never blocks (a FIFO swapped in meanwhile), checked to be the
// file Lstat saw. A missing file is fs.ErrNotExist; anything else that is
// not such a file is errNotSmallRegular. The info is the open file's.
func readSmallFile(path string, maxSize int64) ([]byte, fs.FileInfo, error) {
	lfi, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err //nolint:wrapcheck // callers name the file
	}
	if !lfi.Mode().IsRegular() || lfi.Size() > maxSize {
		return nil, nil, errNotSmallRegular
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, err //nolint:wrapcheck // callers name the file
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, nil, err //nolint:wrapcheck // callers name the file
	}
	if !fi.Mode().IsRegular() || !os.SameFile(lfi, fi) {
		return nil, nil, errNotSmallRegular
	}
	body, err := io.ReadAll(io.LimitReader(f, maxSize+1))
	if err != nil {
		return nil, nil, err //nolint:wrapcheck // callers name the file
	}
	if int64(len(body)) > maxSize {
		return nil, nil, errNotSmallRegular
	}
	return body, fi, nil
}

// readLock reads w's lock from admin ("" = unknown: the listing alone); a
// read that fails is an error (the caller keeps the worktree).
func readLock(w worktree, admin string) (lockState, error) {
	st := lockState{locked: w.Locked}
	if admin == "" {
		return st, nil
	}
	seen, err := readLockFile(admin)
	if err != nil {
		return st, fmt.Errorf("reading the lock of %s: %w", w.Root, err)
	}
	st.seen, st.locked = seen, st.locked || seen.exists
	switch _, err := os.Lstat(filepath.Join(admin, unlockMarker)); {
	case err == nil:
		st.marked = true
	case !errors.Is(err, fs.ErrNotExist):
		return st, fmt.Errorf("reading the lock of %s: %w", w.Root, err)
	}
	return st, nil
}

// sameLockAsListed: now is the lock admin held right before the listing
// (readLocksBefore).
func (b *builder) sameLockAsListed(admin string, now lockSeen) bool {
	before, ok := b.repo.locksBefore[admin]
	return ok && before.same(now)
}

// readLocksBefore reads the lock file of every admin dir under commonDir,
// right before the listing (fix round 3, R3-1): a lock the listing shows
// is judged only while it is still this one. No git runs; an admin dir
// whose lock cannot be read is left out (its lock is never judged).
func readLocksBefore(commonDir string) map[string]lockSeen {
	base := filepath.Join(commonDir, "worktrees")
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil
	}
	out := map[string]lockSeen{}
	for _, e := range entries {
		admin := filepath.Join(base, e.Name())
		if seen, err := readLockFile(admin); err == nil && seen.exists {
			out[admin] = seen
		}
	}
	return out
}

// judge records the lock W3 let pass for root.
func (b *builder) judge(root string, seen lockSeen) {
	b.walkMu.Lock()
	defer b.walkMu.Unlock()
	if b.judged == nil {
		b.judged = map[string]lockSeen{}
	}
	b.judged[root] = seen
}

// judgedLock is the lock W3 let pass for root in these facts, if any.
func (b *builder) judgedLock(root string) (lockSeen, bool) {
	b.walkMu.Lock()
	defer b.walkMu.Unlock()
	seen, ok := b.judged[root]
	return seen, ok
}

// errLockNotRestored: an unlock step failed and the lock could not be put
// back; never a plain refusal (the apply stops, the next pass relocks).
var errLockNotRestored = errors.New("its lock could not be restored; the next cleanup retries")

// errLockChanged keeps a worktree whose lock is not the one W3 judged:
// someone dropped it and locked it again since.
var errLockChanged = errors.New("locked again since the check; that lock is not the one judged")

// lockedMayGo is W3's exception: the worktree's branch is merged and has a
// commit of its own (mergedWithOwnWork) and the worktree has been idle for
// idleFor. Any doubt — no admin dir, a detached HEAD, a failed check — is
// "no".
func (b *builder) lockedMayGo(ctx context.Context, w worktree, admin string) bool {
	return admin != "" && b.mergedWithOwnWork(ctx, w.Branch) && isIdle(ctx, b.deps, w.Root, admin)
}

// mergedWithOwnWork: branch is merged into the default branch by the drift
// check's own detection (workbenchcheck.OpenRepositoryAgainst), under
// which a branch cut from the base with no commit of its own is not
// merged, and it has a commit of its own (hasOwnCommit). git runs through
// the cleanup's runner, a stdin (the squash check's `git patch-id`) through
// its GitInputRunner; a runner without one fails that call. A detached HEAD (""), an unknown default branch or a
// verdict git could not reach is not merged.
func (b *builder) mergedWithOwnWork(ctx context.Context, branch string) bool {
	if branch == "" || b.repo.defaultBranch == "" {
		return false
	}
	g := b.repo.git
	run := func(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
		if name != "git" {
			return nil, -1, fmt.Errorf("the cleanup runs git only, not %s", name)
		}
		ctx, cancel := context.WithTimeout(ctx, gitTimeout)
		defer cancel()
		if stdin == nil {
			return g.run.RunGit(ctx, dir, g.bin, args...)
		}
		in, ok := g.run.(GitInputRunner)
		if !ok {
			return nil, -1, errors.New("the cleanup's git runner cannot feed git an input")
		}
		return in.RunGitInput(ctx, dir, g.bin, stdin, args...)
	}
	repo := workbenchcheck.OpenRepositoryAgainst(ctx, b.repo.folder, b.repo.defaultBranch, run)
	return repo.BranchMerge(ctx, branch) == workbenchcheck.BranchMerged && b.hasOwnCommit(ctx, branch)
}

// hasOwnCommit is W3's evidence that a branch the merge check let pass has
// a commit of its own (final review C2). The merge check is patch
// equivalence: a branch cut from a pushed feature tip with no commit of its
// own reads as merged once that feature is squash-merged, yet every commit
// of it is the feature's. So: a commit of branch outside the default branch
// that no other local branch and no remote-tracking ref but origin's copy
// of branch reaches is its own; when none is, branch still has one only if
// it has no commit outside the default branch at all (merged by a merge or
// a fast-forward, which the merge check judges by itself). Commits inside
// the default branch are never weighed against other branches: every branch
// cut from it since reaches them. Branch names hold no glob character (git
// check-ref-format), so each pattern matches its ref alone. An error — git
// cannot run, the branch is gone — is no evidence.
func (b *builder) hasOwnCommit(ctx context.Context, branch string) bool {
	g, dir := b.repo.git, b.repo.folder
	own, err := g.output(ctx, dir, "rev-list", "-1", "refs/heads/"+branch, "--not",
		"--exclude="+branch, "--branches", "--exclude=origin/"+branch, "--remotes")
	if err != nil {
		return false
	}
	if strings.TrimSpace(string(own)) != "" {
		return true
	}
	// Against the default branch's refs that exist; none: every commit is
	// outside, so no evidence.
	args := []string{"rev-list", "-1", "refs/heads/" + branch, "--not"}
	for _, ref := range []string{"refs/heads/" + b.repo.defaultBranch, "refs/remotes/origin/" + b.repo.defaultBranch} {
		switch _, code, err := g.exitCode(ctx, dir, "rev-parse", "--verify", "--quiet", ref+"^{commit}"); {
		case err != nil:
			return false
		case code == 0:
			args = append(args, ref)
		}
	}
	outside, err := g.output(ctx, dir, args...)
	return err == nil && strings.TrimSpace(string(outside)) == ""
}

// restoreScope runs restoreLocks in every repository whose lock the apply
// holds (r.scope.locked) — right after the locks, before any fact is
// loaded, so an evaluation that then fails still leaves no worktree
// unlocked (fix round 1, F6). A folder whose repository could not be told
// was never locked and is not restored.
func restoreScope(ctx context.Context, d Deps, r Request) []string {
	if d.Git == nil || r.scope == nil {
		return nil
	}
	bin, ok := d.Git.GitBinary()
	if !ok {
		return nil
	}
	// The canonical common dirs whose locks Apply holds (fix round 2,
	// R2-2): a folder symlink retargeted since never moves the restore to
	// another repository. A caller without Deps.Lock holds the locks itself;
	// its keys are read here, once.
	keys := r.scope.locked
	if d.Lock == nil {
		keys, _ = lockKeys(ctx, d, r.scope.folders(r.Sweep))
	}
	g := gitCmd{run: d.Git, bin: bin}
	var notes []string
	for _, common := range keys {
		// git is pointed at the common dir itself (--git-dir): no folder
		// is resolved again.
		notes = append(notes, restoreLocks(ctx, g, common)...)
	}
	return notes
}

// restoreLocks turns every unlock marker of the repository at commonDir
// whose worktree still exists — or cannot be told gone — back into its lock
// (relock), before anything is evaluated. It returns a note per marker it could not restore; such a
// marker stays and W3 keeps its worktree (errUnlockPending) until a later
// apply restores it. A marker whose worktree is gone is left: git drops its
// admin dir with it.
func restoreLocks(ctx context.Context, g gitCmd, commonDir string) []string {
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
		// Only a tree that does not exist is gone. One that cannot be read now
		// (EACCES, a volume not mounted) is locked again through its admin
		// entry, which git reaches by --git-dir (final review F4): left
		// unlocked, git's own `worktree prune` could drop it.
		if fi, err := os.Stat(root); errors.Is(err, fs.ErrNotExist) || err == nil && !fi.IsDir() {
			continue
		}
		if err := relock(ctx, g, "", commonDir, admin, root); err != nil {
			notes = append(notes, err.Error())
		}
	}
	return notes
}

// relock undoes an unlock of ours: when root is not locked now, `git
// worktree lock` with the reason the marker saved; then the marker goes.
// A worktree locked meanwhile (killed before the unlock, or locked by an
// agent since) keeps that lock. git runs in folder, or — gitDir set (the
// restore) — with --git-dir=gitDir. The lock runs even when ctx is done (a
// stopping daemon), within gitTimeout. On failure the marker stays.
func relock(ctx context.Context, g gitCmd, folder, gitDir, admin, root string) error {
	marker := filepath.Join(admin, unlockMarker)
	saved, _, err := readSmallFile(marker, smallFileMax)
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
		if gitDir != "" {
			// Named, not discovered from the working directory (fix round
			// 3, R3-2): a bare common dir under safe.bareRepository=explicit
			// is found only so.
			folder, args = gitDir, append([]string{"--git-dir=" + gitDir}, args...)
		}
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

// unlockForRemoval unlocks root for the removal that follows at once, but
// only the lock W3 judged in the final re-check (judged; ok false = W3 saw
// no lock, so a lock now is someone else's and git's refusal of the remove
// keeps the worktree for them): the lock file, read again, must be that
// one (errLockChanged otherwise); it is saved in the marker (written and
// synced first), then `git worktree unlock`. true when it unlocked (the
// caller relocks if the removal fails). A failure leaves the worktree
// locked as it was (relock) and is returned: the worktree stays.
func (a *applier) unlockForRemoval(ctx context.Context, root, admin string, judged lockSeen, ok bool) (bool, error) {
	if !ok || admin == "" {
		return false, nil
	}
	now, err := readLockFile(admin)
	switch {
	case err != nil:
		return false, fmt.Errorf("reading the lock of %s: %w", root, err)
	case !now.exists:
		return false, nil // unlocked meanwhile: nothing to undo
	case !now.same(judged):
		return false, errLockChanged
	}
	if err := writeMarker(filepath.Join(admin, unlockMarker), []byte(now.body)); err != nil {
		return false, fmt.Errorf("saving the lock of %s: %w", root, err)
	}
	uctx, cancel := context.WithTimeout(ctx, gitTimeout)
	_, _, err = a.git.run.RunGit(uctx, a.folder, a.git.bin, "worktree", "unlock", root)
	cancel()
	if err != nil {
		if rerr := relock(ctx, a.git, a.folder, "", admin, root); rerr != nil {
			// Not a plain refusal: the worktree may be left unlocked (fix
			// round 2, R2-6); the apply stops, the marker stays.
			return false, fmt.Errorf("%w: unlocking %s: %v; locking it again: %v", errLockNotRestored, root, err, rerr)
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
// after the final re-check, whose facts b holds. A worktree whose lock W3
// let pass there (merged and idle) is unlocked first (unlockForRemoval)
// and locked again when the removal fails; it is then kept as
// check_failed. As in settleGit, only git's own refusal lets the apply go
// on: any other failure of the unlock or the removal (a marker that cannot
// be written, git that cannot run) stops it.
func (a *applier) removeWorktreeNow(ctx context.Context, it *Item, root string, b *builder) {
	// The repository pass: the live runs read once more, after the final
	// re-check's walks (#2402 fix round 1).
	switch err := a.liveClear(ctx, root); {
	case errors.Is(err, errLiveInIt):
		keepItem(it, ReasonSessionInIt, err.Error())
		return
	case err != nil:
		a.fail(it, err)
		return
	}
	admin := b.repo.adminDirs[root]
	judged, ok := b.judgedLock(root)
	unlocked, err := a.unlockForRemoval(ctx, root, admin, judged, ok)
	var gitErr *GitError
	switch {
	case errors.Is(err, errLockChanged):
		keepItem(it, ReasonLocked, err.Error())
		return
	case errors.Is(err, errLockNotRestored):
		a.fail(it, err)
		return
	case err != nil && errors.As(err, &gitErr) && gitErr.Code > 0:
		keepItem(it, ReasonCheckFailed, err.Error())
		return
	case err != nil:
		a.fail(it, err)
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
	rerr := relock(ctx, a.git, a.folder, "", admin, root)
	if rerr != nil {
		detail = fmt.Sprintf("removing it failed (%v); locking it again failed, the next cleanup retries: %v", err, rerr)
	}
	keepItem(it, ReasonCheckFailed, detail)
	if rerr != nil || code <= 0 || !errors.As(err, &gitErr) {
		a.halt = err // only git's refusal, relocked, lets the apply go on
	}
}
