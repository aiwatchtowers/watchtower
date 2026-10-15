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
	tmp, err := os.MkdirTemp("", "wt-review-")
	if err != nil {
		return "", err
	}
	defer func() { _ = os.RemoveAll(tmp) }()
	env := []string{"GIT_INDEX_FILE=" + filepath.Join(tmp, "index")}
	if r.hasHead(ctx) {
		if _, err := r.git(ctx, env, "read-tree", "HEAD"); err != nil {
			return "", err
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

func (r *Repo) hasHead(ctx context.Context) bool {
	_, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
	return err == nil
}

// TreeExists reports whether sha names an object in the repository (a pruned snapshot does not).
func (r *Repo) TreeExists(ctx context.Context, sha string) bool {
	_, err := r.git(ctx, nil, "cat-file", "-e", sha+"^{tree}")
	return err == nil
}
