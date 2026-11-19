package cmd

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"watchtower/internal/sessioncleanup"
)

// A coach Accept or Roll Back of a pull request works in a scratch worktree
// <workspace>/coach-pr/<id> and removes it on every path; a process killed
// meanwhile leaves it behind (spec 2026-11-19-coach-repo-edits-as-prs §5).
// `workbench cleanup` lists such folders older than a day and removes them
// on an --apply that names no --item (a whole apply), outside an agent's
// terminal session. The next Accept of the same
// proposal, or `git worktree prune` once the folder is gone, drops the
// repository's registration of it. Plain file-system work: no git.

// coachScratchAge is how old a scratch folder must be to count as left
// over: an Accept or Roll Back runs for 3 minutes at most.
const coachScratchAge = 24 * time.Hour

// coachScratchItem is one left-over scratch folder.
type coachScratchItem struct {
	Path       string `json:"path"`
	ModifiedAt string `json:"modified_at"`
	Removed    bool   `json:"removed"`
	Error      string `json:"error,omitempty"`
}

// cleanupJSON is `workbench cleanup --json`: the cleanup's result plus the
// coach's left-over scratch folders (no key when there are none).
type cleanupJSON struct {
	sessioncleanup.Result
	CoachScratch []coachScratchItem `json:"coach_scratch,omitempty"`
}

// coachScratchName is a scratch folder's name: the proposal id
// (workbenchgit.Publish's <Scratch>/<ID>).
var coachScratchName = regexp.MustCompile(`^[1-9][0-9]*$`)

// coachScratchLeftovers lists the scratch folders of dir older than
// coachScratchAge at now; a missing dir has none. No link is followed: dir
// itself must be a real folder, and only real folders named like a
// proposal id are listed (a symlink is never listed, so never removed).
func coachScratchLeftovers(dir string, now time.Time) ([]coachScratchItem, error) {
	root, err := os.Lstat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, nil
	case err != nil:
		return nil, err
	case !root.IsDir(): // a symlink (or a file) in place of the folder
		return nil, fmt.Errorf("%s is not a folder (a link is not followed)", dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []coachScratchItem
	for _, e := range entries {
		if !e.IsDir() || !coachScratchName.MatchString(e.Name()) { // a symlink is not IsDir here
			continue
		}
		info, err := os.Lstat(filepath.Join(dir, e.Name()))
		if err != nil || !info.IsDir() || now.Sub(info.ModTime()) < coachScratchAge {
			continue
		}
		out = append(out, coachScratchItem{Path: filepath.Join(dir, e.Name()),
			ModifiedAt: info.ModTime().UTC().Format(time.RFC3339)})
	}
	return out, nil
}

// removeCoachScratch removes the listed folders.
func removeCoachScratch(items []coachScratchItem) {
	for i := range items {
		it := &items[i]
		if err := os.RemoveAll(it.Path); err != nil {
			it.Error = err.Error()
			continue
		}
		it.Removed = true
	}
}

// coachScratchStep lists the workspace's left-over scratch folders and, on
// an --apply naming no --item outside an agent's terminal session, removes
// them. A failure
// to read the folder is a note on stderr, never the cleanup's failure.
func coachScratchStep(errOut io.Writer, f cleanupFlags, caller int64, now time.Time) []coachScratchItem {
	if f.sweep { // a sweep is of one workbench's repository; the scratch folders are the workspace's
		return nil
	}
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return nil
	}
	items, err := coachScratchLeftovers(filepath.Join(cfg.WorkspaceDir(), coachScratchDir), now)
	if err != nil {
		fmt.Fprintf(errOut, "cleanup: reading the coach's scratch folders: %v\n", err)
		return nil
	}
	if f.apply && len(f.items) == 0 && caller == 0 {
		removeCoachScratch(items)
	}
	return items
}

// printCoachScratch prints the left-over scratch folders after the result;
// applied: an --apply ran, so a folder not removed was kept.
func printCoachScratch(w io.Writer, items []coachScratchItem, applied bool) {
	for _, it := range items {
		status := "remove"
		switch {
		case it.Removed:
			status = "removed"
		case it.Error != "":
			status = "failed"
		case applied:
			status = "keep"
		}
		line := fmt.Sprintf("  %-7s %-8s %s — a coach pull request's scratch folder left since %s", status, "coach-pr",
			it.Path, it.ModifiedAt)
		if it.Error != "" {
			line += " (error: " + it.Error + ")"
		}
		fmt.Fprintln(w, line)
	}
}
