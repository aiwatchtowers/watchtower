package sessioncleanup

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// gitTimeout bounds every git call of a plan (spec §4).
const gitTimeout = 30 * time.Second

// gitCmd is the located binary and the runner, bound to the repository.
type gitCmd struct {
	run GitRunner
	bin string
}

// output runs git in dir and returns its stdout; a non-zero exit is an error.
func (g gitCmd) output(ctx context.Context, dir string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	out, _, err := g.run.RunGit(ctx, dir, g.bin, args...)
	return out, err
}

// exitCode runs git in dir and returns its exit code; an error only when
// git could not run or exited with a code other than 0 or 1.
func (g gitCmd) exitCode(ctx context.Context, dir string, args ...string) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	_, code, err := g.run.RunGit(ctx, dir, g.bin, args...)
	if code == 0 || code == 1 {
		return code, nil
	}
	return code, err
}

// worktree is one entry of `git worktree list --porcelain`.
type worktree struct {
	Root, Head, Branch string // Branch: short name, "" = detached
	Main, Bare         bool
	Locked, Prunable   bool
}

// branchRef is one local branch and its tip.
type branchRef struct{ Name, Sha string }

// repoState is the workbench repository as one evaluation sees it.
type repoState struct {
	git           gitCmd
	folder        string // the workbench folder, symlink-resolved
	commonDir     string
	defaultBranch string // "" = none found
	worktrees     []worktree
	branches      []branchRef
	adminDirs     map[string]string // worktree root -> <common>/worktrees/<name>
	contained     map[string]bool   // sha -> in the default branch or a remote ref
}

// readRepo inventories the repository holding folder.
func readRepo(ctx context.Context, g gitCmd, folder string) (*repoState, error) {
	r := &repoState{git: g, folder: folder, contained: map[string]bool{}}
	out, err := g.output(ctx, folder, "rev-parse", "--git-common-dir")
	if err != nil {
		return nil, fmt.Errorf("locating the repository of %s: %w", folder, err)
	}
	r.commonDir = absFrom(folder, strings.TrimSpace(string(out)))
	if out, err = g.output(ctx, folder, "worktree", "list", "--porcelain"); err != nil {
		return nil, fmt.Errorf("listing worktrees: %w", err)
	}
	r.worktrees = parseWorktrees(out)
	for i := range r.worktrees {
		r.worktrees[i].Root = resolvePath(r.worktrees[i].Root)
	}
	if r.branches, err = readBranches(ctx, g, folder); err != nil {
		return nil, err
	}
	r.defaultBranch = r.findDefaultBranch(ctx)
	if r.adminDirs, err = readAdminDirs(r.commonDir); err != nil {
		return nil, err
	}
	return r, nil
}

func absFrom(dir, p string) string {
	if !filepath.IsAbs(p) {
		p = filepath.Join(dir, p)
	}
	return resolvePath(p)
}

// resolvePath is p absolute, cleaned and symlink-resolved when it exists.
func resolvePath(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if real, err := filepath.EvalSymlinks(p); err == nil {
		return real
	}
	return filepath.Clean(p)
}

// parseWorktrees reads `git worktree list --porcelain`; the first entry is
// the main worktree.
func parseWorktrees(out []byte) []worktree {
	var list []worktree
	var cur *worktree
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		key, val, _ := strings.Cut(sc.Text(), " ")
		if key == "worktree" {
			list = append(list, worktree{Root: filepath.Clean(val), Main: len(list) == 0})
			cur = &list[len(list)-1]
			continue
		}
		if cur != nil {
			cur.setField(key, val)
		}
	}
	return list
}

func (w *worktree) setField(key, val string) {
	switch key {
	case "HEAD":
		w.Head = val
	case "branch":
		w.Branch = strings.TrimPrefix(val, "refs/heads/")
	case "bare":
		w.Bare = true
	case "locked":
		w.Locked = true
	case "prunable":
		w.Prunable = true
	}
}

func readBranches(ctx context.Context, g gitCmd, folder string) ([]branchRef, error) {
	out, err := g.output(ctx, folder, "for-each-ref", "--format=%(refname:short)%00%(objectname)", "refs/heads")
	if err != nil {
		return nil, fmt.Errorf("listing branches: %w", err)
	}
	var list []branchRef
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if name, sha, ok := strings.Cut(line, "\x00"); ok && name != "" {
			list = append(list, branchRef{Name: name, Sha: sha})
		}
	}
	return list, nil
}

// findDefaultBranch: origin/HEAD's target, else main, else master, else "".
func (r *repoState) findDefaultBranch(ctx context.Context) string {
	if out, err := r.git.output(ctx, r.folder, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"); err == nil {
		if name := strings.TrimPrefix(strings.TrimSpace(string(out)), "refs/remotes/origin/"); name != "" {
			return name
		}
	}
	for _, name := range []string{"main", "master"} {
		if _, ok := r.branchTip(name); ok {
			return name
		}
	}
	return ""
}

func (r *repoState) branchTip(name string) (string, bool) {
	for _, b := range r.branches {
		if b.Name == name {
			return b.Sha, true
		}
	}
	return "", false
}

// readAdminDirs maps each linked worktree's root to its admin dir by
// reading <common>/worktrees/*/gitdir (the path of the worktree's .git).
func readAdminDirs(commonDir string) (map[string]string, error) {
	base := filepath.Join(commonDir, "worktrees")
	entries, err := os.ReadDir(base)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", base, err)
	}
	out := map[string]string{}
	for _, e := range entries {
		admin := filepath.Join(base, e.Name())
		b, err := os.ReadFile(filepath.Join(admin, "gitdir"))
		if err != nil {
			continue // not a worktree admin dir, or a broken one git lists as prunable
		}
		root := filepath.Dir(strings.TrimSpace(string(b)))
		out[resolvePath(root)] = admin
	}
	return out, nil
}

// isContained reports whether sha is an ancestor of the default branch or
// contained in any refs/remotes/* ref. No fetch: what the remote refs say now.
func (r *repoState) isContained(ctx context.Context, sha string) (bool, error) {
	if v, ok := r.contained[sha]; ok {
		return v, nil
	}
	in, err := r.inDefault(ctx, sha)
	if err == nil && !in {
		in, err = r.onRemote(ctx, sha)
	}
	if err != nil {
		return false, err
	}
	r.contained[sha] = in
	return in, nil
}

func (r *repoState) inDefault(ctx context.Context, sha string) (bool, error) {
	if _, ok := r.branchTip(r.defaultBranch); !ok {
		return false, nil
	}
	code, err := r.git.exitCode(ctx, r.folder, "merge-base", "--is-ancestor", sha, "refs/heads/"+r.defaultBranch)
	if err != nil {
		return false, fmt.Errorf("checking %s against %s: %w", short(sha), r.defaultBranch, err)
	}
	return code == 0, nil
}

func (r *repoState) onRemote(ctx context.Context, sha string) (bool, error) {
	out, err := r.git.output(ctx, r.folder, "for-each-ref", "--count=1", "--contains", sha,
		"--format=%(refname)", "refs/remotes")
	if err != nil {
		return false, fmt.Errorf("looking for %s on the remote refs: %w", short(sha), err)
	}
	return strings.TrimSpace(string(out)) != "", nil
}

// isDirty: `git status --porcelain` in the worktree lists modified, staged
// or untracked files (ignored files do not count).
func (r *repoState) isDirty(ctx context.Context, root string) (bool, error) {
	out, err := r.git.output(ctx, root, "status", "--porcelain", "--untracked-files=normal")
	if err != nil {
		return false, fmt.Errorf("reading the status of %s: %w", root, err)
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}

// operationMarkers are the files a merge, rebase, cherry-pick, revert or
// bisect in progress leaves in the worktree's git dir.
var operationMarkers = []string{"rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"}

// operationIn is the marker found in the worktree's git dir, "" for none.
func (r *repoState) operationIn(root string) (string, error) {
	gitDir, ok := r.adminDirs[root]
	if !ok {
		return "", fmt.Errorf("no git dir found for %s", root)
	}
	for _, m := range operationMarkers {
		_, err := os.Lstat(filepath.Join(gitDir, m))
		if err == nil {
			return m, nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
	}
	return "", nil
}

// worktreeBirth is the birth time of the worktree's admin dir, set by
// `git worktree add` (spec §2).
func (r *repoState) worktreeBirth(root string) (time.Time, bool) {
	admin, ok := r.adminDirs[root]
	if !ok {
		return time.Time{}, false
	}
	return birthTime(admin)
}

// branchBirth is the time of the first entry of the branch's reflog; false
// when there is no reflog or it does not parse.
func (r *repoState) branchBirth(name string) (time.Time, bool) {
	f, err := os.Open(filepath.Join(r.commonDir, "logs", "refs", "heads", filepath.FromSlash(name)))
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		return time.Time{}, false
	}
	return reflogTime(line)
}

// reflogTime reads "<old> <new> <name> <email> <unix> <tz>\t<msg>".
func reflogTime(line string) (time.Time, bool) {
	head, _, _ := strings.Cut(line, "\t")
	f := strings.Fields(head)
	if len(f) < 2 {
		return time.Time{}, false
	}
	sec, err := strconv.ParseInt(f[len(f)-2], 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(sec, 0), true
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
