package sessioncleanup

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
)

// observed is what a session saw (spec §2 rule 1): the ledger's roots and
// branches, its linked targets' branches and the agent's declared items.
// named are the branches a target or the agent named: a worktree with one
// of them checked out is observed too (a subagent whose hooks carried no cwd
// of its own). A ledger branch alone never adopts a worktree: the session
// may have had it checked out elsewhere. placedCwd is a placed row's own
// folder_path (symlink-resolved); placedRoot and placedBranch are its
// worktree and worktree_branch owned by record (born no later than the row,
// observePlacement); all "" for every other row.
//
// Command ledger rows (auto cleanup spec 2026-11-10 §2a) name what the
// agent created: a worktree row adds its root and names its branch, a
// branch row names its branch only — its root is the repository's top
// level, never a worktree root. scratch and scratchIDs are the session's
// Claude scratchpad (§2b): the `<base>/claude-<uid>` dirs and the agent
// session ids no other row has (loadScratch).
type observed struct {
	roots, branches, named              map[string]bool
	placedCwd, placedRoot, placedBranch string
	scratch                             []string
	scratchIDs                          map[string]bool
}

const (
	sourceCommand = "command"
	kindBranch    = "branch"
)

func observe(rows []db.SessionWorktree, targetBranches, declaredWorktrees, declaredBranches []string) observed {
	o := observed{roots: map[string]bool{}, branches: map[string]bool{}, named: map[string]bool{}}
	for _, r := range rows {
		command := r.Source == sourceCommand
		if !command || r.Kind != kindBranch {
			o.roots[resolvePath(r.Root)] = true
		}
		if r.Branch != "" {
			o.branches[r.Branch] = true
			if command {
				o.named[r.Branch] = true
			}
		}
	}
	for _, p := range declaredWorktrees {
		o.roots[resolvePath(p)] = true
	}
	for _, b := range append(append([]string(nil), targetBranches...), declaredBranches...) {
		if b != "" {
			o.branches[b], o.named[b] = true, true
		}
	}
	return o
}

// sawWorktree: the session recorded or declared the root, a branch a
// target or the agent named is checked out there, or it is a linked
// worktree inside the session's Claude scratchpad.
func (o observed) sawWorktree(w worktree) bool {
	return o.roots[w.Root] || (w.Branch != "" && o.named[w.Branch]) || (!w.Main && !w.Bare && o.inScratch(w.Root))
}

// inScratch reports whether root lies strictly inside
// `<scratch dir>/<any one segment>/<uuid>/` for one of scratchIDs.
func (o observed) inScratch(root string) bool {
	for _, dir := range o.scratch {
		rest, ok := strings.CutPrefix(root, dir+"/")
		if !ok {
			continue
		}
		segs := strings.Split(rest, "/")
		if len(segs) >= 3 && segs[0] != "" && segs[2] != "" && o.scratchIDs[segs[1]] {
			return true
		}
	}
	return false
}

// scratchBases is the set of temp roots Claude Code may write its
// scratchpads under, symlink-resolved and deduplicated: /tmp (where the
// CLI writes whatever this process's TMPDIR is), os.TempDir() and
// $CLAUDE_CODE_TMPDIR when set. A base that does not resolve is left out.
// A package variable so tests point it at a temp dir.
var scratchBases = func() []string {
	cands := []string{"/tmp", os.TempDir()}
	if d := os.Getenv("CLAUDE_CODE_TMPDIR"); d != "" {
		cands = append(cands, d)
	}
	var out []string
	seen := map[string]bool{}
	for _, c := range cands {
		r, err := filepath.EvalSymlinks(c)
		if err != nil || !filepath.IsAbs(r) || seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, r)
	}
	return out
}

// scratchDirs is `<base>/claude-<uid>` under every scratch base.
func scratchDirs() []string {
	var out []string
	for _, b := range scratchBases() {
		out = append(out, filepath.Join(b, fmt.Sprintf("claude-%d", os.Getuid())))
	}
	return out
}

// placedWorktree reports whether w is the row's own placed worktree: a
// linked worktree, and the longest listed root containing placedCwd.
// Watchtower created this worktree and branch for this row (board #229); by
// record they are the session's, although born before the row (spec
// 2026-10-14-session-worktrees-design.md §9).
func (o observed) placedWorktree(w worktree, all []worktree) bool {
	if o.placedCwd == "" || w.Main || w.Bare || !pathWithin(o.placedCwd, w.Root) {
		return false
	}
	for _, other := range all {
		if len(other.Root) > len(w.Root) && pathWithin(o.placedCwd, other.Root) {
			return false
		}
	}
	return true
}

// Ownership reasons.
const (
	ReasonNotThisSession       = "not_this_session"
	ReasonExistedBeforeSession = "existed_before_session"
	ReasonCreatedUnknown       = "created_unknown"
)

// bornReason is "" when an item born at birth (known or not) is younger
// than the session (spec §2 rule 2), else why it is kept. A zero session
// start is unknown too: nothing can be shown younger than it.
//
// terminal_sessions.created_at is stored with second precision (migration
// 00084 writes strftime('%Y-%m-%dT%H:%M:%SZ','now')), so the real start lies
// anywhere in [sessionCreated, sessionCreated+1s). Fail closed: an item born
// inside that second may predate the session, so it counts as owned only
// when born at or after sessionCreated+1s.
func bornReason(birth time.Time, known bool, sessionCreated time.Time) string {
	switch {
	case !known || sessionCreated.IsZero():
		return ReasonCreatedUnknown
	case birth.Before(sessionCreated.Add(time.Second)):
		return ReasonExistedBeforeSession
	}
	return ""
}

// bornByRecord: an item born at birth (known) can be the placed row's own,
// made by placement before the row was inserted — born no later than the
// row's created_at+1s (second precision). An unknown birth or session start
// owns nothing by record (fail closed), and neither does a later-born item:
// a reused wt/<slug> of a later session is not this row's.
func bornByRecord(birth time.Time, known bool, sessionCreated time.Time) bool {
	return known && !sessionCreated.IsZero() && !birth.After(sessionCreated.Add(time.Second))
}
