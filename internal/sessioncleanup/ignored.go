package sessioncleanup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"path/filepath"
	"strings"
)

// cacheDirs are the folders a build or a package manager makes again by
// itself: a git-ignored path with one of them as a path component is not
// unsaved work (#1878).
var cacheDirs = map[string]bool{
	".build":       true,
	"DerivedData":  true,
	"build":        true,
	"node_modules": true,
	".swiftpm":     true,
}

// integrationFiles and integrationPrefixes are what Watchtower's own
// integration writes into a workbench folder or a session worktree (hooks,
// the cleanup permission, the shipped skills); Watchtower writes them again
// whenever it sets a folder up, so they are not the agent's work either.
var (
	integrationFiles = map[string]bool{
		".claude/settings.local.json": true,
		".codex/hooks.json":           true,
		".codex/config.toml":          true,
	}
	integrationPrefixes = []string{".claude/skills/watchtower-", ".agents/skills/watchtower-"}
)

// regenerable reports whether rel (slash-separated, relative to the
// worktree's root) is a cache, Watchtower's integration or Finder's
// .DS_Store: something removing the worktree loses nothing of.
func regenerable(rel string) bool {
	rel = strings.TrimSuffix(rel, "/")
	for _, part := range strings.Split(rel, "/") {
		if cacheDirs[part] {
			return true
		}
	}
	if path.Base(rel) == ".DS_Store" || integrationFiles[rel] {
		return true
	}
	for _, p := range integrationPrefixes {
		if strings.HasPrefix(rel, p) {
			return true
		}
	}
	return false
}

// ignoredWork is the first git-ignored path in the worktree at root that is
// not regenerable, "" when there is none. `git worktree remove` deletes
// ignored files with the worktree, and an agent's notes often live there (a
// plan's .superpowers/sdd ledger, #1878). git lists an ignored folder as one
// entry ("dir/"); such a folder is walked without following symlinks and
// counts at its first file that is not regenerable. Any git or read failure
// is an error, so the catch keeps the worktree (check_failed).
func (r *repoState) ignoredWork(ctx context.Context, root string) (string, error) {
	out, err := r.git.output(ctx, root, "status", "--porcelain", "-z", "--ignored=matching",
		"--untracked-files=all", "--ignore-submodules=all")
	if err != nil {
		return "", fmt.Errorf("listing the ignored files of %s: %w", root, err)
	}
	for _, rec := range bytes.Split(out, []byte{0}) {
		entry, ok := bytes.CutPrefix(rec, []byte("!! "))
		if !ok || len(entry) == 0 {
			continue
		}
		rel := string(entry)
		if regenerable(rel) {
			continue
		}
		if !strings.HasSuffix(rel, "/") {
			return rel, nil
		}
		found, err := firstUnsaved(ctx, root, strings.TrimSuffix(rel, "/"))
		if err != nil || found != "" {
			return found, err
		}
	}
	return "", nil
}

// errFound stops firstUnsaved's walk at the first unsaved file.
var errFound = errors.New("found")

// firstUnsaved walks the ignored folder dir (relative to root) and returns
// the first entry in it that is not regenerable; a regenerable folder is
// skipped whole and symlinks are judged as entries, never followed.
func firstUnsaved(ctx context.Context, root, dir string) (string, error) {
	var found string
	err := filepath.WalkDir(filepath.Join(root, filepath.FromSlash(dir)), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if regenerable(rel) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		found = rel
		return errFound
	})
	if errors.Is(err, errFound) {
		return found, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading the ignored folder %s: %w", dir, err)
	}
	return "", nil
}
