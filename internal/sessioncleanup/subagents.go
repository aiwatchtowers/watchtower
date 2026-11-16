package sessioncleanup

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/agentlog"
)

// NoteSubagentRecordsUnreadable is the plan's note that Claude Code's
// subagent records no longer say what the session's subagents made (auto
// cleanup spec 2026-11-10 §2a): a subagent worktree its record does not
// name, or the projects directory gone. Nothing is adopted from them; the
// Desktop's notice says so.
const NoteSubagentRecordsUnreadable = "subagent_records_unreadable"

// Bounds of the subagent record reads: a real meta file is a few hundred
// bytes, and a meta file is written once when its subagent starts, so a
// record of a worktree's subagent is no older than the worktree's birth
// minus recordSlack.
const (
	maxSubagentMetaBytes = 1 << 20
	recordSlack          = 60 * time.Second
)

// defaultClaudeProjectsDir is the projects directory the session feed
// reads subagent records from: ~/.claude/projects (agentlog.DefaultClaudeDir,
// never $CLAUDE_CONFIG_DIR — review-rules §5: an env override could point
// Watchtower at a TCC-protected folder); "" when the home directory is
// unknown.
func defaultClaudeProjectsDir() string {
	dir := agentlog.DefaultClaudeDir()
	if !filepath.IsAbs(dir) {
		return ""
	}
	return filepath.Join(dir, "projects")
}

// bornAt reads births: a worktree's (by root) and a branch's (by name).
type bornAt struct {
	worktree, branch func(string) (time.Time, bool)
}

// subagentMeta is the part of a subagent record
// (<projects dir>/<slug>/<uuid>/subagents/agent-<id>.meta.json) the cleanup
// reads: a subagent started with a worktree of its own names it.
type subagentMeta struct {
	SpawnedWithWorktree bool   `json:"spawnedWithWorktree"`
	WorktreePath        string `json:"worktreePath"`
	WorktreeBranch      string `json:"worktreeBranch"`
}

// namedWorktree is one record that names a worktree: the subagent's
// worktree path (symlink-resolved), its branch, and when this row acquired
// the uuid whose record it is.
type namedWorktree struct {
	branch   string
	acquired time.Time
}

// subagentWorktrees is source §2a of the auto cleanup spec (2026-11-10): the
// worktrees, and their branches, that the subagents of ids' Claude Code
// sessions were started in. ids are the counted uuids with the moment this
// row acquired each; ended is when the row's terminal ended (zero = still
// live, no upper bound); wts are the planned repository's worktrees.
//
// For each uuid the record files sit in <projects dir>/<slug>/<uuid>/
// subagents, beside the transcript <slug>/<uuid>.jsonl. A missing
// transcript or subagents folder means no subagents (Claude Code prunes old
// transcripts); a record without spawnedWithWorktree and an absolute
// worktreePath adopts nothing. A linked worktree of wts whose root is a
// record's worktreePath is the session's when it was born at or after the
// uuid's acquisition +1 s (second precision, as bornReason); its record's
// worktreeBranch is the session's under the same rule. A branch of a
// worktree the agent already removed is not named (fail closed, v1 limit).
//
// note reports that the records no longer say what the subagents made: the
// projects directory is gone, or a linked worktree named agent-<id>, born
// while the row lived, is named by no record and either its
// agent-<id>.meta.json sits in a counted uuid's folder (the keys moved or
// were renamed) or it exists nowhere under the projects directory while no
// record there was written at or after the worktree's birth − recordSlack
// (the records stopped landing where this looks), or a project folder could
// not be searched. A counted uuid's subagents folder or record that exists
// but cannot be read or parsed is err: a broken read of the session's own
// records is never "nothing to clean".
func subagentWorktrees(projectsDir string, ids map[string]time.Time, ended time.Time, wts []worktree,
	born bornAt) (roots, branches map[string]bool, note bool, err error) {
	roots, branches = map[string]bool{}, map[string]bool{}
	if len(ids) == 0 {
		return roots, branches, false, nil
	}
	if projectsDir == "" {
		return roots, branches, true, nil
	}
	if fi, err := os.Stat(projectsDir); errors.Is(err, fs.ErrNotExist) {
		return roots, branches, true, nil
	} else if err != nil {
		return nil, nil, false, fmt.Errorf("reading %s: %w", projectsDir, err)
	} else if !fi.IsDir() {
		return roots, branches, true, nil
	}
	named, metaIn, blind, err := readSessionRecords(projectsDir, ids)
	if err != nil {
		return nil, nil, false, err
	}
	note = blind
	var lo time.Time
	for _, at := range ids {
		if lo.IsZero() || at.Before(lo) {
			lo = at
		}
	}
	var unnamed []agentWorktree // agent-<id> worktrees no record names
	for _, w := range wts {
		if w.Main || w.Bare {
			continue
		}
		birth, known := born.worktree(w.Root)
		if n, ok := named[w.Root]; ok {
			after := n.acquired.Add(time.Second)
			if !known || birth.Before(after) {
				continue
			}
			roots[w.Root] = true
			if n.branch == "" {
				continue
			}
			if bb, ok := born.branch(n.branch); ok && !bb.Before(after) {
				branches[n.branch] = true
			}
			continue
		}
		id := filepath.Base(w.Root)
		if !strings.HasPrefix(id, "agent-") || !known || !bornWhileLived(birth, lo, ended) {
			continue
		}
		if since, ok := metaIn[id]; ok {
			if !birth.Before(since.Add(time.Second)) {
				note = true // its record is in a counted folder but does not name it
			}
			continue
		}
		unnamed = append(unnamed, agentWorktree{id: id, birth: birth})
	}
	if len(unnamed) == 0 {
		return roots, branches, note, nil
	}
	return roots, branches, note || recordsMoved(projectsDir, unnamed), nil
}

// agentWorktree is a linked worktree named agent-<id> no record names.
type agentWorktree struct {
	id    string // agent-<id>, the record's file name without .meta.json
	birth time.Time
}

// bornWhileLived: born at or after lo +1 s and, when the row's terminal has
// ended, before ended +1 s (second precision).
func bornWhileLived(birth, lo, ended time.Time) bool {
	if birth.Before(lo.Add(time.Second)) {
		return false
	}
	return ended.IsZero() || birth.Before(ended.Add(time.Second))
}

// readSessionRecords reads the subagent records of ids' sessions: named
// maps each worktreePath a record names (symlink-resolved) to its branch
// and its uuid's acquisition, metaIn each record's agent-<id> to that
// acquisition. A uuid with no transcript or no subagents folder has none.
// blind is a project folder that could not be searched for a transcript
// (another project's, most likely): the records there are unseen, which is
// the note, not a failed plan. A counted uuid's own subagents folder or
// record that cannot be read is err.
func readSessionRecords(projectsDir string, ids map[string]time.Time) (map[string]namedWorktree,
	map[string]time.Time, bool, error) {
	named, metaIn := map[string]namedWorktree{}, map[string]time.Time{}
	dirs, err := os.ReadDir(projectsDir)
	if err != nil {
		return nil, nil, false, fmt.Errorf("reading %s: %w", projectsDir, err)
	}
	blind := false
	for _, d := range dirs {
		if !d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			continue
		}
		for uuid, acquired := range ids {
			found, err := readUUIDRecords(filepath.Join(projectsDir, d.Name()), uuid, acquired, named, metaIn)
			if err != nil {
				return nil, nil, false, err
			}
			blind = blind || !found
		}
	}
	return named, metaIn, blind, nil
}

// readUUIDRecords reads uuid's records under slugDir; searched is false when
// slugDir could not be searched for uuid's transcript.
func readUUIDRecords(slugDir, uuid string, acquired time.Time, named map[string]namedWorktree,
	metaIn map[string]time.Time) (searched bool, err error) {
	if fi, err := os.Lstat(filepath.Join(slugDir, uuid+".jsonl")); err != nil || !fi.Mode().IsRegular() {
		// No transcript: pruned, or never in this folder; a folder that
		// cannot be searched is the caller's note.
		return err == nil || errors.Is(err, fs.ErrNotExist), nil
	}
	dir := filepath.Join(slugDir, uuid, "subagents")
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return true, fmt.Errorf("reading %s: %w", dir, err)
		}
		return true, nil // no subagents (a symlinked folder is never followed)
	}
	files, err := os.ReadDir(dir)
	if err != nil {
		return true, fmt.Errorf("reading %s: %w", dir, err)
	}
	for _, f := range files {
		id, ok := strings.CutSuffix(f.Name(), ".meta.json")
		if !ok || !strings.HasPrefix(id, "agent-") {
			continue
		}
		m, err := readSubagentMeta(filepath.Join(dir, f.Name()))
		if err != nil {
			return true, err
		}
		if prev, ok := metaIn[id]; !ok || acquired.After(prev) {
			metaIn[id] = acquired
		}
		if !m.SpawnedWithWorktree || !filepath.IsAbs(m.WorktreePath) {
			continue
		}
		root := resolvePath(m.WorktreePath)
		if prev, ok := named[root]; !ok || acquired.After(prev.acquired) {
			named[root] = namedWorktree{branch: m.WorktreeBranch, acquired: acquired}
		}
	}
	return true, nil
}

// readSubagentMeta reads one record: a regular file of at most
// maxSubagentMetaBytes holding a JSON object, else an error.
func readSubagentMeta(path string) (subagentMeta, error) {
	var m subagentMeta
	fi, err := os.Lstat(path)
	switch {
	case err != nil:
		return m, fmt.Errorf("reading the subagent record %s: %w", path, err)
	case !fi.Mode().IsRegular():
		return m, fmt.Errorf("the subagent record %s is not a regular file", path)
	case fi.Size() > maxSubagentMetaBytes:
		return m, fmt.Errorf("the subagent record %s is %d bytes", path, fi.Size())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return m, fmt.Errorf("reading the subagent record %s: %w", path, err)
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, fmt.Errorf("parsing the subagent record %s: %w", path, err)
	}
	return m, nil
}

// recordsMoved reports whether one of unnamed has no record anywhere under
// the projects directory (<projects dir>/*/*/subagents/agent-*.meta.json)
// while no record there was written at or after its birth − recordSlack:
// records no longer land where the cleanup reads them. A worktree whose
// record lies elsewhere (another session's subagent) says nothing, and so
// does an old one whose transcript was pruned while later records exist.
// Only record files count: the subagents' .jsonl transcripts beside them
// are appended to all the time. A folder the scan cannot read (another
// project's session folder, most likely) reports true too: its records are
// unseen, so the worktree stays unadopted and the plan carries the note
// rather than failing.
func recordsMoved(projectsDir string, unnamed []agentWorktree) bool {
	exists := map[string]bool{}
	var newest time.Time
	slugs, err := os.ReadDir(projectsDir)
	if err != nil {
		return true
	}
	for _, s := range slugs {
		if !s.IsDir() || s.Type()&fs.ModeSymlink != 0 {
			continue
		}
		sessions, err := os.ReadDir(filepath.Join(projectsDir, s.Name()))
		if err != nil {
			return true
		}
		for _, sess := range sessions {
			if !sess.IsDir() || sess.Type()&fs.ModeSymlink != 0 {
				continue
			}
			dir := filepath.Join(projectsDir, s.Name(), sess.Name(), "subagents")
			files, err := os.ReadDir(dir)
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			if err != nil {
				return true
			}
			for _, f := range files {
				id, ok := strings.CutSuffix(f.Name(), ".meta.json")
				if !ok || !strings.HasPrefix(id, "agent-") {
					continue
				}
				exists[id] = true
				info, err := f.Info()
				if err != nil {
					return true
				}
				if info.ModTime().After(newest) {
					newest = info.ModTime()
				}
			}
		}
	}
	for _, w := range unnamed {
		if !exists[w.id] && newest.Before(w.birth.Add(-recordSlack)) {
			return true
		}
	}
	return false
}
