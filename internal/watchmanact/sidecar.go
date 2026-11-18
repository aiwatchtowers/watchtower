// Package watchmanact is the acting side of Watchman (spec
// 2026-11-16-watchman-design §2, §5): the arm sidecar the guard layers read,
// and — in later tasks — the git hooks and the twin worker. internal/watchman
// stays the non-acting leaf (WATCHMAN-06).
package watchmanact

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// sidecarName is the arm sidecar's file name in the workspace.
const sidecarName = "watchman.armed"

// SidecarPath is <workspace>/watchman.armed: what is armed, for the guard
// layers that must decide without the database (the git hooks, the guard
// hook when the database cannot be read).
func SidecarPath(workspace string) string { return filepath.Join(workspace, sidecarName) }

// Sidecar is the sidecar's content: the armed sessions, their worktrees
// (each once) and whether any target is armed.
type Sidecar struct {
	Sessions     []int64
	Worktrees    []string
	TargetsArmed bool
}

// WriteSidecar replaces the sidecar atomically (temp file + rename) with one
// `session <id>` line per armed session, followed by `worktree <abs path>`
// the first time its worktree appears, and `targets-armed` when any target
// is armed. Nothing armed writes an empty file. A worktree path with a line
// break cannot be a line: its session is listed, the worktree is not.
func WriteSidecar(path string, sessions []db.ArmedSession, targetsArmed bool) error {
	var b bytes.Buffer
	seen := map[string]bool{}
	for _, s := range sessions {
		fmt.Fprintf(&b, "session %d\n", s.SessionID)
		wt := filepath.Clean(s.Folder)
		if s.Folder == "" || seen[wt] || strings.ContainsAny(wt, "\r\n") {
			continue
		}
		seen[wt] = true
		fmt.Fprintf(&b, "worktree %s\n", wt)
	}
	if targetsArmed {
		b.WriteString("targets-armed\n")
	}
	if err := fsutil.WriteFileAtomic(path, b.Bytes(), 0o644); err != nil {
		return fmt.Errorf("writing the watchman sidecar: %w", err)
	}
	return nil
}

// ReadSidecar reads the sidecar; a missing file is nothing armed. Lines it
// does not know are skipped.
func ReadSidecar(path string) (Sidecar, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Sidecar{}, nil
	}
	if err != nil {
		return Sidecar{}, fmt.Errorf("reading the watchman sidecar: %w", err)
	}
	var sc Sidecar
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case line == "targets-armed":
			sc.TargetsArmed = true
		case strings.HasPrefix(line, "session "):
			if id, err := strconv.ParseInt(strings.TrimPrefix(line, "session "), 10, 64); err == nil {
				sc.Sessions = append(sc.Sessions, id)
			}
		case strings.HasPrefix(line, "worktree "):
			sc.Worktrees = append(sc.Worktrees, strings.TrimPrefix(line, "worktree "))
		}
	}
	return sc, nil
}
