// Package watchmanact is the acting side of Watchman (spec
// 2026-11-16-watchman-design §2, §5): the arm sidecar the guard layers read,
// and — in later tasks — the git hooks and the twin worker. internal/watchman
// stays the non-acting leaf (WATCHMAN-06).
package watchmanact

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
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
// (each once), whether any target is armed, and the owner's extra limits
// (the guard hook applies them when it cannot read the database).
type Sidecar struct {
	Sessions     []int64
	Worktrees    []string
	TargetsArmed bool
	Limits       []db.WatchmanExtraLimit // Kind and Pattern; no ID
	// LimitsUnavailable: the owner's limits could not all be written (the
	// read failed, or a row cannot be a line); the guard then denies an
	// armed call as unreadable.
	LimitsUnavailable bool
}

// limitsUnavailableLine marks a sidecar whose owner's limits are not all in it.
const limitsUnavailableLine = "limits-unavailable"

// WriteSidecar replaces the sidecar atomically (temp file + rename) with one
// `session <id>` line per armed session, followed by `worktree <abs path>`
// the first time its worktree appears, and `targets-armed` when any target
// is armed, then one `limit <kind> <pattern>` line per owner's extra limit.
// Nothing armed and no limit writes an empty file. A worktree path with a
// line break cannot be a line: its session is listed, the worktree is not.
// A limit that cannot be one line (a line break in its kind or pattern, a
// blank in its kind) is not written; the `limits-unavailable` marker is, so
// the guard fails closed (the CLI refuses such a pattern, but a row can
// come from elsewhere).
func WriteSidecar(path string, sessions []db.ArmedSession, targetsArmed bool, limits ...db.WatchmanExtraLimit) error {
	return writeSidecar(path, sessions, targetsArmed, limits, false)
}

// writeSidecar is WriteSidecar; limitsUnavailable writes the marker
// whatever the limits are.
func writeSidecar(path string, sessions []db.ArmedSession, targetsArmed bool, limits []db.WatchmanExtraLimit, limitsUnavailable bool) error {
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
	for _, l := range limits {
		if l.Pattern == "" || strings.ContainsAny(l.Kind+l.Pattern, "\r\n") || strings.ContainsAny(l.Kind, " \t") {
			limitsUnavailable = true
			continue
		}
		fmt.Fprintf(&b, "limit %s %s\n", l.Kind, l.Pattern)
	}
	if limitsUnavailable {
		b.WriteString(limitsUnavailableLine + "\n")
	}
	if err := fsutil.WriteFileAtomic(path, b.Bytes(), 0o644); err != nil {
		return fmt.Errorf("writing the watchman sidecar: %w", err)
	}
	return nil
}

// sidecarAfterRead, a test seam, runs inside RefreshSidecar's lock between
// the database read and the write; nil outside tests.
var sidecarAfterRead func()

// RefreshSidecar rewrites the workspace's sidecar from the database under
// a cross-process flock (<sidecar>.lock) held from the read through the
// rename, so of two writers — `watchman arm|disarm` and the daemon's upkeep
// — the one that reads later also writes later: a stale state never
// overwrites a newer one. It returns the arming rows it was written from.
// The arming read failing writes nothing (the old file stays); the owner's
// limits failing still writes the arming with the limits-unavailable
// marker, and returns that error.
func RefreshSidecar(ctx context.Context, workspace string, d *db.DB) ([]db.WatchmanArming, error) {
	path := SidecarPath(workspace)
	unlock, err := fsutil.LockFile(ctx, path+".lock")
	if err != nil {
		return nil, fmt.Errorf("locking the watchman sidecar: %w", err)
	}
	defer unlock()
	arming, err := d.ListWatchmanArming()
	if err != nil {
		return nil, err
	}
	sessions, err := d.WatchmanArmedSessions()
	if err != nil {
		return arming, err
	}
	limits, limitsErr := d.WatchmanExtraLimits()
	if sidecarAfterRead != nil {
		sidecarAfterRead()
	}
	targets := slices.ContainsFunc(arming, func(a db.WatchmanArming) bool { return a.Scope == "target" })
	if err := writeSidecar(path, sessions, targets, limits, limitsErr != nil); err != nil {
		return arming, err
	}
	return arming, limitsErr
}

// ReadSidecar reads the sidecar; a missing file is nothing armed. Lines it
// does not know are skipped, so a file written before the limit lines reads
// as no owner's limits.
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
		case line == limitsUnavailableLine:
			sc.LimitsUnavailable = true
		case strings.HasPrefix(line, "session "):
			if id, err := strconv.ParseInt(strings.TrimPrefix(line, "session "), 10, 64); err == nil {
				sc.Sessions = append(sc.Sessions, id)
			}
		case strings.HasPrefix(line, "worktree "):
			sc.Worktrees = append(sc.Worktrees, strings.TrimPrefix(line, "worktree "))
		case strings.HasPrefix(line, "limit "):
			if kind, pattern, ok := strings.Cut(strings.TrimPrefix(line, "limit "), " "); ok && pattern != "" {
				sc.Limits = append(sc.Limits, db.WatchmanExtraLimit{Kind: kind, Pattern: pattern})
			}
		}
	}
	return sc, nil
}
