// Package workbenchcheck finds board drift on a project board: targets whose
// status disagrees with the git work they are linked to (branch, pull
// request), and in-progress work that has not moved for days. Mechanical —
// no AI call, no database write, nothing written to the folder's
// repository (PROJ-07, docs/inventory/workbench.md).
package workbenchcheck

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Kinds of drift.
const (
	// KindMergedOpen: the target's branch is merged into the default branch
	// (or its pull request is merged) while the target is still open.
	KindMergedOpen = "merged_but_open"
	// KindDoneUnmerged: the target is done while its branch still holds
	// commits the default branch lacks (or its pull request is still open).
	KindDoneUnmerged = "done_but_unmerged"
	// KindBranchMissing: an in-progress/in-review target names a branch that
	// exists neither locally nor on origin (merged and deleted, or never
	// created).
	KindBranchMissing = "branch_missing"
	// KindPRClosed: the target's pull request was closed without a merge
	// while the target is still open.
	KindPRClosed = "pr_closed_unmerged"
	// KindStale: an in-progress leaf target with no status change, no edit
	// and no commit on its branch for longer than Options.StaleAfter.
	KindStale = "stale"
)

// DoneRecentWindow limits the done-but-unmerged rule to targets closed in
// the last two weeks: an old done target whose branch still lingers locally
// (a squash merge older than the patch-id window, a branch nobody deleted) is
// history, not drift worth stopping a turn for.
const DoneRecentWindow = 14 * 24 * time.Hour

// DefaultStaleAfter is how long in-progress work may sit without movement
// before it counts as stale.
const DefaultStaleAfter = 3 * 24 * time.Hour

// Finding is one drifted target.
type Finding struct {
	TargetID int    `json:"target_id"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Branch   string `json:"branch,omitempty"`
	PR       string `json:"pr,omitempty"`
	Kind     string `json:"kind"`
	Detail   string `json:"detail"` // what was observed
	Fix      string `json:"fix"`    // what to do about it on the board
}

// Blocking reports whether the Stop hook stops the turn for the finding:
// only when the evidence is local and certain — a merged branch on an open
// target, a missing branch, a closed pull request. KindStale can be
// legitimate (waiting on someone), and KindDoneUnmerged is an offline guess
// (the local origin/<default> may predate a merge made on GitHub, and a
// merge style the patch-id match cannot see reads as unmerged): both are
// shown in the brief and by `workbench check`, never forced on a turn.
func (f Finding) Blocking() bool { return f.Kind != KindStale && f.Kind != KindDoneUnmerged }

// Line renders the finding as one line for the brief, the CLI and the hook.
func (f Finding) Line() string {
	return fmt.Sprintf("#%d %q [%s]: %s — %s", f.TargetID, f.Title, f.Status, f.Detail, f.Fix)
}

// Report is the outcome of one check.
type Report struct {
	WorkbenchID int64  `json:"project_id"`
	Git         bool   `json:"git"`            // the folder is a git work tree
	Base        string `json:"base,omitempty"` // the default branch compared against, e.g. origin/main
	PRChecked   bool   `json:"pr_checked"`     // pull request states were read through gh
	// Incomplete: the context ran out before every target was checked; the
	// findings cover only the targets checked in time.
	Incomplete bool      `json:"incomplete,omitempty"`
	Findings   []Finding `json:"findings"`
	Notes      []string  `json:"notes,omitempty"` // why a part of the check was skipped
}

// BlockingFindings returns the findings the Stop hook acts on.
func (r Report) BlockingFindings() []Finding {
	var out []Finding
	for _, f := range r.Findings {
		if f.Blocking() {
			out = append(out, f)
		}
	}
	return out
}

// Runner runs name with args in dir, feeding it stdin (nil = none), and
// returns its stdout, the exit code (0 on success, -1 when the process could
// not run at all) and an error for anything but a clean run. The default is
// ExecRunner.
type Runner func(ctx context.Context, dir string, stdin []byte, name string, args ...string) (out []byte, code int, err error)

// Options configures one check.
type Options struct {
	Folder     string
	StaleAfter time.Duration // 0 = DefaultStaleAfter
	Now        time.Time     // zero = time.Now()
	// Network allows reading pull request states through the gh CLI. Off
	// in the Stop hook's and the brief's fast path.
	Network bool
	Run     Runner // nil = ExecRunner
}

// Check inspects every target of board against the folder's git state. It
// never fails: a part it cannot check is skipped and named in Notes.
func Check(ctx context.Context, projectID int64, board []db.BoardNode, o Options) Report {
	if o.StaleAfter <= 0 {
		o.StaleAfter = DefaultStaleAfter
	}
	if o.Now.IsZero() {
		o.Now = time.Now()
	}
	if o.Run == nil {
		o.Run = ExecRunner
	}
	rep := Report{WorkbenchID: projectID, Findings: []Finding{}}
	g := newGitState(ctx, o)
	rep.Git = g.workTree
	rep.Base = g.baseName()
	rep.Notes = append(rep.Notes, g.notes...)
	var pr *prChecker
	switch {
	case o.Network && g.noGit:
		// gh reads the repository by running git from its own PATH, which
		// without the developer tools is the /usr/bin/git shim.
		rep.Notes = append(rep.Notes, noGitPRNote)
	case o.Network:
		pr = newPRChecker(ctx, o)
		rep.PRChecked = pr.available
		rep.Notes = append(rep.Notes, pr.notes...)
	}
	c := checker{g: g, pr: pr, o: o, openRefs: openRefs(board)}
	walkBoard(board, func(n db.BoardNode) {
		if rep.Incomplete {
			return
		}
		found := c.checkTarget(ctx, n)
		// A git call cut short by the deadline reads as "not found" or "not
		// merged": never report what a cut-short target seemed to show.
		if ctx.Err() != nil {
			rep.Incomplete = true
			rep.Notes = append(rep.Notes, "time ran out; only part of the board was checked")
			return
		}
		rep.Findings = append(rep.Findings, found...)
	})
	if pr != nil {
		if note := pr.summary(); note != "" {
			rep.PRChecked = false
			rep.Notes = append(rep.Notes, note)
		}
	}
	if ctx.Err() != nil && !rep.Incomplete {
		// The deadline hit during the repository probe: its conclusions
		// (no work tree, no default branch) are not trustworthy either.
		rep.Incomplete = true
		rep.Findings = []Finding{}
		rep.Notes = []string{"time ran out; only part of the board was checked"}
	}
	return rep
}

func walkBoard(level []db.BoardNode, fn func(db.BoardNode)) {
	for _, n := range level {
		fn(n)
		walkBoard(n.Children, fn)
	}
}

func isClosed(status string) bool { return status == "done" || status == "dismissed" }

// openRefs collects every branch and pull request an open target carries:
// a done target sharing one with open work (the feature target, the plan's
// remaining tasks) is a finished step of unfinished work, not drift.
func openRefs(board []db.BoardNode) map[string]bool {
	refs := map[string]bool{}
	walkBoard(board, func(n db.BoardNode) {
		if isClosed(n.Target.Status) {
			return
		}
		if b := strings.TrimSpace(n.Target.Branch); b != "" {
			refs["branch:"+b] = true
		}
		if p := strings.TrimSpace(n.Target.PR); p != "" {
			refs["pr:"+strings.TrimPrefix(p, "#")] = true
		}
	})
	return refs
}

// checker holds what every target's check shares.
type checker struct {
	g        *gitState
	pr       *prChecker
	o        Options
	openRefs map[string]bool
}

// targetCtx is one target as the rules see it.
type targetCtx struct {
	status    string
	branch    string
	prRef     string
	parent    bool // has sub-targets: its status follows them (PROJ-05)
	sharedRef bool // a done target whose branch/PR open work still carries
	mk        findingMaker
}

// checkTarget runs every rule on one target; at most one finding per kind.
func (c checker) checkTarget(ctx context.Context, n db.BoardNode) []Finding {
	if skipped(n, c.o.Now) {
		return nil
	}
	tc := c.contextOf(n)
	var out findingSet
	var tip branchTip
	if tc.branch != "" && c.g.ready() && tc.branch != c.g.defaultName {
		tip = c.g.branchState(ctx, tc.branch)
		out.add(branchFinding(tc, tip, c.g.baseName()))
	}
	if tc.prRef != "" && c.pr != nil {
		out.add(c.pr.finding(ctx, tc))
	}
	out.add(staleFinding(n, tip, c.o, tc.mk))
	return out.list
}

// skipped: a dismissed target, or one done long ago, is history.
func skipped(n db.BoardNode, now time.Time) bool {
	st := n.Target.Status
	return st == "dismissed" || (st == "done" && !recentlyMoved(n, now, DoneRecentWindow))
}

func (c checker) contextOf(n db.BoardNode) targetCtx {
	t := n.Target
	branch, prRef := strings.TrimSpace(t.Branch), strings.TrimSpace(t.PR)
	return targetCtx{
		status: t.Status, branch: branch, prRef: prRef, parent: len(n.Children) > 0,
		sharedRef: (branch != "" && c.openRefs["branch:"+branch]) || (prRef != "" && c.openRefs["pr:"+strings.TrimPrefix(prRef, "#")]),
		mk: func(kind, detail, fix string) Finding {
			return Finding{TargetID: t.ID, Title: t.Text, Status: t.Status, Branch: branch, PR: prRef, Kind: kind, Detail: detail, Fix: fix}
		},
	}
}

// findingSet keeps one finding per kind (git and gh can both say "merged").
type findingSet struct{ list []Finding }

func (s *findingSet) add(f Finding, ok bool) {
	if ok && !slices.ContainsFunc(s.list, func(g Finding) bool { return g.Kind == f.Kind }) {
		s.list = append(s.list, f)
	}
}

type findingMaker func(kind, detail, fix string) Finding

const (
	fixMergedOpen = "set it done with update_target; if only part of it landed, split it into a done sub-target " +
		"for what landed and a sub-target for what remains; if it is kept open on purpose, clear its branch/pr (update_target branch \"\")"
	// fixMergedOpenParent: a parent's status follows its children
	// (PROJ-05), so the fix is on the sub-targets, never the parent itself.
	fixMergedOpenParent = "its status follows its sub-targets: set each sub-target whose work landed done, and keep open " +
		"(or split off) only what truly remains; if work continues on purpose, clear its branch/pr (update_target branch \"\")"
	fixDoneUnmerged = "if it was merged on GitHub, `git fetch` and check again; otherwise merge it, or move the target " +
		"back to in_review until it is merged; if the work landed another way, clear its branch (update_target branch \"\")"
	fixBranchMissing = "if it was merged and deleted, set the target done; if the branch has another name, set it " +
		"(update_target branch); if the work has not started, set the target back to todo"
	fixPRClosed = "the pull request was closed without a merge: reopen or replace it (update_target pr), or move the target to blocked/dismissed"
	fixStale    = "if it is finished, move it on (in_review / done); if it waits on someone, set it blocked and say why in add_comment"
)

// branchFinding applies the git rules. An unknown answer (a failed git call)
// never becomes a finding.
func branchFinding(tc targetCtx, tip branchTip, base string) (Finding, bool) {
	switch {
	case tip.state == tipMissing:
		if tc.status == "in_progress" || tc.status == "in_review" {
			return tc.mk(KindBranchMissing, fmt.Sprintf("branch %s is found neither locally nor on origin (as of the last fetch)", tc.branch), fixBranchMissing), true
		}
	case tip.state != tipFound:
	case !isClosed(tc.status) && tip.merge == merged:
		return tc.mk(KindMergedOpen, fmt.Sprintf("branch %s is merged into %s", tc.branch, base), mergedOpenFix(tc)), true
	case tc.status == "done" && !tc.sharedRef && tip.merge == notMerged && tip.ahead > 0:
		return tc.mk(KindDoneUnmerged, fmt.Sprintf("branch %s has %d commit(s) not in %s", tc.branch, tip.ahead, base), fixDoneUnmerged), true
	}
	return Finding{}, false
}

func mergedOpenFix(tc targetCtx) string {
	if tc.parent {
		return fixMergedOpenParent
	}
	return fixMergedOpen
}

// staleFinding flags an in-progress leaf whose latest movement — status
// change, edit, or a commit on its branch — is older than StaleAfter. A
// parent's status follows its children (PROJ-05), so only leaves count.
func staleFinding(n db.BoardNode, tip branchTip, o Options, mk findingMaker) (Finding, bool) {
	if n.Target.Status != "in_progress" || len(n.Children) > 0 {
		return Finding{}, false
	}
	last := latest(parseTime(n.StatusSince), parseTime(n.Target.UpdatedAt), tip.committed)
	if last.IsZero() || o.Now.Sub(last) <= o.StaleAfter {
		return Finding{}, false
	}
	days := int(o.Now.Sub(last) / (24 * time.Hour))
	return mk(KindStale, fmt.Sprintf("in progress with no movement for %d day(s)", days), fixStale), true
}

func recentlyMoved(n db.BoardNode, now time.Time, window time.Duration) bool {
	last := latest(parseTime(n.StatusSince), parseTime(n.Target.UpdatedAt))
	return !last.IsZero() && now.Sub(last) <= window
}

func parseTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(s))
	if err != nil {
		return time.Time{}
	}
	return t
}

func latest(ts ...time.Time) time.Time {
	var out time.Time
	for _, t := range ts {
		if t.After(out) {
			out = t
		}
	}
	return out
}
