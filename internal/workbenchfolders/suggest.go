package workbenchfolders

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// MaxRepoWalk caps RepoRoot's walk up a path (spec 2026-11-18 §7, "hook"
// row): a deeper path is never mapped to a repository.
const MaxRepoWalk = 64

// gitFileLimit caps what RepoRoot reads of a linked worktree's `.git` file
// (one `gitdir:` line).
const gitFileLimit = 4096

// RepoRoot maps path to its repository root by walking up for `.git` — no git
// process (spec §6.7) — checking path itself and at most MaxRepoWalk levels
// in all. A linked worktree (a `.git` file pointing into
// `<repo>/.git/worktrees/<name>`) maps to its main repository, so every
// worktree of a repository counts as that repository. ok is false when no
// `.git` is found within the cap. path must be absolute and cleaned.
func RepoRoot(path string) (root string, ok bool) {
	dir := path
	for range MaxRepoWalk {
		fi, err := os.Lstat(filepath.Join(dir, ".git"))
		if err == nil {
			if fi.Mode().IsRegular() {
				if main, ok := worktreeMain(dir); ok {
					return main, true
				}
			}
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
	return "", false
}

// worktreeMain is the main repository of the linked worktree at dir, read
// from its `.git` file (`gitdir: <repo>/.git/worktrees/<name>`); ok is false
// for any other `.git` file (a submodule's points into `.git/modules`).
func worktreeMain(dir string) (string, bool) {
	f, err := os.Open(filepath.Join(dir, ".git"))
	if err != nil {
		return "", false
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, gitFileLimit))
	if err != nil {
		return "", false
	}
	line, _, _ := bytes.Cut(raw, []byte("\n"))
	gitdir, ok := strings.CutPrefix(strings.TrimSpace(string(line)), "gitdir:")
	if !ok {
		return "", false
	}
	gitdir = strings.TrimSpace(gitdir)
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(dir, gitdir)
	}
	gitdir = filepath.Clean(gitdir)
	sep := string(filepath.Separator)
	i := strings.LastIndex(gitdir, sep+".git"+sep+"worktrees"+sep)
	if i <= 0 {
		return "", false
	}
	return gitdir[:i], true
}

// ProtectedDirs lists Watchtower's own state directories, which a bench
// folder may neither be, sit inside, nor contain: every workspace's data, the
// default config directory and the Desktop's Application Support. `workbench
// create`, `folder add|locate` and suggest_workbench_folder share it.
func ProtectedDirs() []string {
	var dirs []string
	if root, err := config.DataRoot(); err == nil {
		dirs = append(dirs, root)
	}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".config", "watchtower"),
			filepath.Join(home, "Library", "Application Support", "Watchtower"))
	}
	return dirs
}

// Suggestable checks path as an agent's folder suggestion for workbench
// workbenchID (spec §6.7): stored as Add would store it and refused as Add
// would refuse it (not_found, already_here, nested, a folder no workbench
// may have — ProtectedDirs), except that a live folder of another bench is
// no refusal — it comes back as other, so the card offers the merge
// (§6.13). root is the folder's repository root (RepoRoot; the folder itself
// outside any repository); a linked worktree whose repository is a live
// folder of this bench is already_here. Nothing is written.
func Suggestable(ctx context.Context, d *db.DB, workbenchID int64, path string) (folder, root string, other *db.Workbench, err error) {
	folder, err = normalize(path, ProtectedDirs())
	if err != nil {
		return "", "", nil, err
	}
	err = checkFree(ctx, d, workbenchID, 0, folder)
	var r *Refusal
	if errors.As(err, &r) && r.Code == CodeOtherBench && r.OtherBench != nil {
		other, err = r.OtherBench, nil
	}
	if err != nil {
		return "", "", nil, err
	}
	root, ok := RepoRoot(folder)
	if !ok {
		root = folder
	}
	if strings.EqualFold(root, folder) {
		return folder, root, other, nil
	}
	live, err := liveFolders(ctx, d, workbenchID, 0)
	if err != nil {
		return "", "", nil, err
	}
	for i := range live {
		if f := &live[i]; strings.EqualFold(f.FolderPath, root) {
			return "", "", nil, &Refusal{Code: CodeAlreadyHere, Folder: f,
				Detail: fmt.Sprintf("%s is a worktree of %s, already on this bench as %s.", folder, root, f.Name)}
		}
	}
	return folder, root, other, nil
}
