// Package gitdir finds the git work tree holding a directory by reading
// files only — a walk up for a ".git" entry, a linked work tree's "gitdir:"
// pointer and the HEAD file — and never runs git. The workbench's
// info/exclude upkeep (internal/devpack) and the session-state hook's
// worktree ledger (cmd) share it.
package gitdir

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// pointerMaxBytes caps what is read of a ".git" file or a HEAD file: both
// are one short line.
const pointerMaxBytes = 4096

// FindWorkTree walks up from dir (absolute and cleaned) to the nearest
// directory holding a ".git" entry: root is that directory, gitDir the git
// dir the entry names. found is false, with no error, when no ancestor has
// one. The walk stops at the first ".git" it meets, valid or not: a ".git"
// that is neither a directory nor a "gitdir: <path>" file, or a stat error
// other than "does not exist" (a permission error, say), is returned as an
// error rather than skipped — failing closed, so an unreadable inner
// repository is never mistaken for the enclosing one.
func FindWorkTree(dir string) (root, gitDir string, found bool, err error) {
	for cur := dir; ; cur = filepath.Dir(cur) {
		gitDir, found, err := GitDirAt(cur)
		if err != nil {
			return "", "", false, err
		}
		if found {
			return cur, gitDir, true, nil
		}
		if filepath.Dir(cur) == cur {
			return "", "", false, nil
		}
	}
}

// GitDirAt reads dir's own ".git" entry: found is false when there is none;
// otherwise gitDir is the entry itself when it is a directory, or the path
// a "gitdir: <path>" file names (a relative path is taken from dir). Any
// other ".git", and a stat error other than "does not exist", is an error.
func GitDirAt(dir string) (gitDir string, found bool, err error) {
	p := filepath.Join(dir, ".git")
	info, err := os.Stat(p)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("inspecting %s: %w", p, err)
	}
	if info.IsDir() {
		return p, true, nil
	}
	if !info.Mode().IsRegular() {
		return "", false, fmt.Errorf("%s is neither a git directory nor a gitdir file", p)
	}
	b, err := readPointer(p)
	if err != nil {
		return "", false, err
	}
	target, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	target = strings.TrimSpace(target)
	if !ok || target == "" {
		return "", false, fmt.Errorf("%s is neither a git directory nor a gitdir file", p)
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(dir, target)
	}
	return target, true, nil
}

// reftableHeadStub is the branch a reftable repository's HEAD file names:
// a placeholder kept for old git versions, never the real branch (that
// lives in the reftable, which this package does not read).
const reftableHeadStub = ".invalid"

// HeadBranch is the short branch name gitDir's HEAD file names. It is ""
// — branch unknown — when HEAD is detached, names no local branch, cannot
// be read, or is a reftable repository's ".invalid" stub.
func HeadBranch(gitDir string) string {
	b, err := readPointer(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	ref, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "ref:")
	if !ok {
		return ""
	}
	name, ok := strings.CutPrefix(strings.TrimSpace(ref), "refs/heads/")
	if !ok || name == reftableHeadStub || strings.ContainsAny(name, "\x00\n\r") {
		return ""
	}
	return name
}

// readPointer reads at most pointerMaxBytes of path; a longer file is an
// error (no git pointer file is that long).
func readPointer(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, pointerMaxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	if len(b) > pointerMaxBytes {
		return nil, fmt.Errorf("%s is longer than %d bytes", path, pointerMaxBytes)
	}
	return b, nil
}
