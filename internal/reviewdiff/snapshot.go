package reviewdiff

import (
	"context"
	"os"
	"path/filepath"
	"strings"
)

// Snapshot writes the work tree (tracked and untracked, not ignored) as a
// tree object through a private temporary index and returns its sha. Only
// objects are written; no ref and not the owner's index.
func (r *Repo) Snapshot(ctx context.Context) (string, error) {
	return r.snapshot(ctx, true)
}

// snapshot seeds the temporary index from a copy of the owner's index when
// seedFromOwner and the copy is possible (its stat cache lets add -A skip
// re-hashing unchanged files), else from read-tree HEAD; both give the same
// tree, since add -A re-records every path from the work tree.
func (r *Repo) snapshot(ctx context.Context, seedFromOwner bool) (string, error) {
	tmp, err := os.MkdirTemp("", "wt-review-")
	if err != nil {
		return "", err
	}
	defer func() { _ = os.RemoveAll(tmp) }()
	index := filepath.Join(tmp, "index")
	// The temp index is always written unsplit: a split index would write a
	// sharedindex.<sha> into the owner's $GIT_DIR. Env config outranks the
	// repo config and, unlike a leading -c, keeps the subcommand visible to
	// gitbin.
	env := []string{
		"GIT_INDEX_FILE=" + index,
		"GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=core.splitIndex", "GIT_CONFIG_VALUE_0=false",
	}
	if !seedFromOwner || !r.copyOwnerIndex(ctx, index) {
		head, err := r.hasHead(ctx)
		if err != nil {
			return "", err
		}
		if head {
			if _, err := r.git(ctx, env, "read-tree", "HEAD"); err != nil {
				return "", err
			}
		}
	}
	if _, err := r.git(ctx, env, "add", "-A", "--", "."); err != nil {
		return "", err
	}
	out, err := r.git(ctx, env, "write-tree")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// copyOwnerIndex copies the owner's index file (read only) to dst, keeping
// its mtime so git's racy-entry check still re-hashes a file changed in the
// second the owner's index was written. It refuses a split index (the copy
// would point at a shared index it does not carry) and reports false on any
// failure, so the caller falls back to read-tree HEAD.
func (r *Repo) copyOwnerIndex(ctx context.Context, dst string) bool {
	out, err := r.git(ctx, nil, "rev-parse", "--git-path", "index")
	if err != nil {
		return false
	}
	src := strings.TrimSpace(string(out))
	if !filepath.IsAbs(src) {
		src = filepath.Join(r.dir, src)
	}
	if split, err := r.git(ctx, nil, "config", "--bool", "core.splitIndex"); err == nil && strings.TrimSpace(string(split)) == "true" {
		return false
	}
	if shared, _ := filepath.Glob(filepath.Join(filepath.Dir(src), "sharedindex.*")); len(shared) > 0 {
		return false
	}
	info, err := os.Lstat(src)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return false
	}
	if err := os.WriteFile(dst, data, 0o600); err != nil {
		return false
	}
	if err := os.Chtimes(dst, info.ModTime(), info.ModTime()); err != nil {
		_ = os.Remove(dst)
		return false
	}
	return true
}

// hasHead: HEAD names a commit. A done context is an error, never "no commit".
func (r *Repo) hasHead(ctx context.Context) (bool, error) {
	_, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
	if ctxErr := ctx.Err(); ctxErr != nil {
		return false, ctxErr
	}
	return err == nil, nil
}

// TreeExists reports whether sha names a tree in the repository (a pruned
// snapshot does not). A done context is an error, never "missing".
func (r *Repo) TreeExists(ctx context.Context, sha string) (bool, error) {
	_, err := r.git(ctx, nil, "cat-file", "-e", sha+"^{tree}")
	if ctxErr := ctx.Err(); ctxErr != nil {
		return false, ctxErr
	}
	return err == nil, nil
}
