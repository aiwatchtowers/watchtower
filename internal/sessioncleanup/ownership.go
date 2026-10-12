package sessioncleanup

import (
	"time"

	"watchtower/internal/db"
)

// observed is what a session saw (spec §2 rule 1): the ledger's roots and
// branches, its linked targets' branches and the agent's declared items.
// named are the branches a target or the agent named: a worktree with one
// of them checked out is observed too (a subagent whose hooks carried no cwd
// of its own). A ledger branch alone never adopts a worktree: the session
// may have had it checked out elsewhere.
type observed struct {
	roots, branches, named map[string]bool
}

func observe(rows []db.SessionWorktree, targetBranches, declaredWorktrees, declaredBranches []string) observed {
	o := observed{roots: map[string]bool{}, branches: map[string]bool{}, named: map[string]bool{}}
	for _, r := range rows {
		o.roots[resolvePath(r.Root)] = true
		if r.Branch != "" {
			o.branches[r.Branch] = true
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

// sawWorktree: the session recorded or declared the root, or a branch a
// target or the agent named is checked out there.
func (o observed) sawWorktree(w worktree) bool {
	return o.roots[w.Root] || (w.Branch != "" && o.named[w.Branch])
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
