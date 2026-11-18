// Package workbenchcheck finds board drift on a project board: targets whose
// status disagrees with the git work they are linked to (branch, pull
// request), and in-progress work that has not moved for days. Mechanical —
// no AI call, no database write, nothing written to the folder's
// repository (PROJ-07, docs/inventory/workbench.md).
package workbenchcheck

import (
	"context"
	"fmt"
	"os"
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
	// KindFolderRemoved: the target's folder left the bench, so its branch
	// and pull request are not checked (spec 2026-11-18 §6.3).
	KindFolderRemoved = "folder_removed"
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
// KindFolderRemoved is no git verdict at all, and the agent may not be able
// to act on it (the owner removed the folder): shown, never forced.
func (f Finding) Blocking() bool {
	return f.Kind != KindStale && f.Kind != KindDoneUnmerged && f.Kind != KindFolderRemoved
}

// Line renders the finding as one line for the brief, the CLI and the hook.
func (f Finding) Line() string {
	return fmt.Sprintf("#%d %q [%s]: %s — %s", f.TargetID, f.Title, f.Status, f.Detail, f.Fix)
}

// Report is the outcome of one check.
//
// Git and Base describe Options.Folder (the home folder); a target in
// another folder of the bench is checked in that folder's repository, whose
// notes are prefixed with its path. Skipped names every folder whose branch
// checks did not run: another folder that is missing, not a repository or
// has no default branch, and a missing home folder.
type Report struct {
	WorkbenchID int64  `json:"project_id"`
	Git         bool   `json:"git"`            // the home folder is a git work tree
	Base        string `json:"base,omitempty"` // the home folder's default branch compared against, e.g. origin/main
	PRChecked   bool   `json:"pr_checked"`     // pull request states were read through gh
	// Incomplete: the context ran out before every target was checked; the
	// findings cover only the targets checked in time.
	Incomplete bool         `json:"incomplete,omitempty"`
	Findings   []Finding    `json:"findings"`
	Skipped    []FolderSkip `json:"skipped"`
	Notes      []string     `json:"notes,omitempty"` // why a part of the check was skipped
}

// FolderSkip is a folder whose targets' branches were not checked, and why.
type FolderSkip struct {
	Folder string `json:"folder"`
	Reason string `json:"reason"`
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
	// Folder is the home folder: the repository of every target FolderOf
	// does not place elsewhere.
	Folder string
	// FolderOf names the folder a target's work is in (PROJ-07, spec
	// 2026-11-18 §6.10): its path, and removed when the folder left the
	// bench (the target then gets KindFolderRemoved instead of a git
	// verdict). nil, or a "" path, is Folder.
	FolderOf   func(targetID int64) (path string, removed bool)
	StaleAfter time.Duration // 0 = DefaultStaleAfter
	Now        time.Time     // zero = time.Now()
	// Network allows reading pull request states through the gh CLI. Off
	// in the Stop hook's and the brief's fast path.
	Network bool
	// OpenOnly checks only open targets: every blocking kind is about one,
	// so the Stop hook's verdict is the same without the closed ones. The
	// brief uses it too, so a session start never waits on the closed walk.
	OpenOnly bool
	Run      Runner // nil = ExecRunner
	// clock reads the time for the gh budget; nil = time.Now (tests set it).
	clock func() time.Time
}

// addRunNotes adds what the git and pull-request passes learned while
// walking the board: a filter guard that skipped the squash checks, and a
// pull-request lookup that did not complete (then PRChecked is false).
func addRunNotes(rep *Report, f *folderState) {
	if f.g.guardNote != "" {
		rep.Notes = append(rep.Notes, f.note(f.g.guardNote))
	}
	if f.pr == nil {
		return
	}
	if note := f.pr.summary(); note != "" {
		rep.PRChecked = false
		rep.Notes = append(rep.Notes, f.note(note))
	}
}

// folderState is one folder's repository as the check reads it: probed
// once, however many targets live there.
type folderState struct {
	path    string
	home    bool
	missing bool // the folder is gone from disk (moved or deleted)
	g       *gitState
	pr      *prChecker // made for the folder's first target with a PR
	notes   []string   // what the probe said, prefixed for a non-home folder
}

// missingFolderNote: the folder is gone from disk, so nothing in it is read.
const missingFolderNote = "the folder is missing (moved or deleted?); branch checks skipped"

// openFolder probes the repository at path; a folder gone from disk runs
// no git at all.
func openFolder(ctx context.Context, o Options, path string, home bool) *folderState {
	o.Folder = path
	f := &folderState{path: path, home: home}
	if _, err := os.Stat(path); err != nil {
		f.missing = true
		f.g = &gitState{o: o, notes: []string{missingFolderNote}}
	} else {
		f.g = newGitState(ctx, o)
	}
	for _, n := range f.g.notes {
		f.notes = append(f.notes, f.note(n))
	}
	return f
}

// skip is the folder's FolderSkip when its branch checks cannot run: a
// missing folder always; another folder also when it is no repository or
// has no default branch (the home folder's are Git/Base).
func (f *folderState) skip() (FolderSkip, bool) {
	if !f.missing && (f.home || f.g.ready()) {
		return FolderSkip{}, false
	}
	reason := "branch checks skipped"
	if len(f.g.notes) > 0 {
		reason = f.g.notes[0]
	}
	return FolderSkip{Folder: f.path, Reason: reason}, true
}

// note is n as a report note: a non-home folder's names the folder.
func (f *folderState) note(n string) string {
	if f.home {
		return n
	}
	return f.path + ": " + n
}

// Check inspects every target of board against the git state of the folder
// its work is in (Options.FolderOf; the home folder otherwise). The home
// folder is probed up front, another folder once, when its first target with
// a branch or pull request is checked. It never fails: a part it cannot
// check is skipped and named in Notes.
func Check(ctx context.Context, workbenchID int64, board []db.BoardNode, o Options) Report {
	if o.StaleAfter <= 0 {
		o.StaleAfter = DefaultStaleAfter
	}
	if o.Now.IsZero() {
		o.Now = time.Now()
	}
	if o.Run == nil {
		o.Run = ExecRunner
	}
	rep := Report{WorkbenchID: workbenchID, Findings: []Finding{}, Skipped: []FolderSkip{}}
	home := openFolder(ctx, o, o.Folder, true)
	rep.Git = home.g.workTree
	rep.Base = home.g.baseName()
	rep.Notes = append(rep.Notes, home.notes...)
	if sk, ok := home.skip(); ok {
		rep.Skipped = append(rep.Skipped, sk)
	}
	c := &checker{o: o, folders: map[string]*folderState{o.Folder: home}}
	switch {
	case o.Network && home.g.noGit:
		// gh reads the repository by running git from its own PATH, which
		// without the developer tools is the /usr/bin/git shim.
		rep.Notes = append(rep.Notes, noGitPRNote)
	case o.Network:
		// One sign-in probe and one time budget for every folder's reads.
		var note string
		// The sign-in does not depend on the folder, but the probe needs a
		// working directory that exists: a missing home folder would read as
		// "not signed in" and turn off every folder's PR checks.
		probeDir := o.Folder
		if home.missing {
			probeDir = os.TempDir()
		}
		c.gh, note = newGHSession(ctx, o, probeDir)
		rep.PRChecked = c.gh.available
		if note != "" {
			rep.Notes = append(rep.Notes, note)
		}
	}
	c.openRefs = c.openRefsOf(board)
	// Open targets first: a check its deadline cuts short has then looked at
	// the work the blocking kinds are about.
	for _, open := range []bool{true, false} {
		if !open && o.OpenOnly {
			break
		}
		walkBoard(board, func(n db.BoardNode) {
			if rep.Incomplete || isClosed(n.Target.Status) == open {
				return
			}
			found := c.checkTarget(ctx, n, &rep)
			// A git call cut short by the deadline reads as "not found" or "not
			// merged": never report what a cut-short target seemed to show.
			if ctx.Err() != nil {
				rep.Incomplete = true
				rep.Notes = append(rep.Notes, "time ran out; only part of the board was checked")
				return
			}
			rep.Findings = append(rep.Findings, found...)
		})
	}
	addRunNotes(&rep, home)
	for _, f := range c.opened {
		addRunNotes(&rep, f)
	}
	if ctx.Err() != nil && !rep.Incomplete {
		// The deadline hit during the repository probe: its conclusions
		// (no work tree, no default branch) are not trustworthy either.
		rep.Incomplete = true
		rep.Findings = []Finding{}
		rep.Skipped = []FolderSkip{}
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

// openRefsOf collects every branch and pull request an open target carries,
// per folder: a done target sharing one with open work in the same folder
// (the feature target, the plan's remaining tasks) is a finished step of
// unfinished work, not drift. Another folder's branch of the same name is
// other work.
func (c *checker) openRefsOf(board []db.BoardNode) map[string]bool {
	refs := map[string]bool{}
	walkBoard(board, func(n db.BoardNode) {
		if isClosed(n.Target.Status) {
			return
		}
		folder, _ := c.folderOf(n)
		if b := strings.TrimSpace(n.Target.Branch); b != "" {
			refs[refKey(folder, "branch", b)] = true
		}
		if p := strings.TrimSpace(n.Target.PR); p != "" {
			refs[refKey(folder, "pr", strings.TrimPrefix(p, "#"))] = true
		}
	})
	return refs
}

func refKey(folder, kind, ref string) string { return folder + "\x00" + kind + ":" + ref }

// checker holds what every target's check shares.
type checker struct {
	o        Options
	folders  map[string]*folderState // by path, the home folder's included
	opened   []*folderState          // the other folders, in the order probed
	openRefs map[string]bool
	gh       *ghSession // nil without Network or without git
}

// folderOf is the path of the folder n's work is in and whether that
// folder left the bench.
func (c *checker) folderOf(n db.BoardNode) (string, bool) {
	if c.o.FolderOf == nil {
		return c.o.Folder, false
	}
	path, removed := c.o.FolderOf(int64(n.Target.ID))
	if path == "" {
		return c.o.Folder, removed
	}
	return path, removed
}

// folder is path's repository state, probed on first use; the probe's notes
// join rep then.
func (c *checker) folder(ctx context.Context, path string, rep *Report) *folderState {
	if f, ok := c.folders[path]; ok {
		return f
	}
	f := openFolder(ctx, c.o, path, false)
	c.folders[path] = f
	c.opened = append(c.opened, f)
	rep.Notes = append(rep.Notes, f.notes...)
	if sk, ok := f.skip(); ok {
		rep.Skipped = append(rep.Skipped, sk)
	}
	return f
}

// prOf is f's pull request reader, made on first use; nil without gh, or
// for a folder gone from disk (gh reads the repository there).
func (c *checker) prOf(f *folderState) *prChecker {
	if c.gh == nil || f.missing {
		return nil
	}
	if f.pr == nil {
		f.pr = &prChecker{folder: f.path, run: c.o.Run, gh: c.gh}
	}
	return f.pr
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

// checkTarget runs every rule on one target in its folder's repository; at
// most one finding per kind. A target whose folder left the bench gets
// KindFolderRemoved for its branch/PR instead of a git verdict.
func (c *checker) checkTarget(ctx context.Context, n db.BoardNode, rep *Report) []Finding {
	if skipped(n, c.o.Now) {
		return nil
	}
	path, removed := c.folderOf(n)
	tc := c.contextOf(n, path)
	var out findingSet
	var tip branchTip
	switch {
	case removed:
		out.add(folderRemovedFinding(tc, path))
	case tc.branch != "" || tc.prRef != "":
		f := c.folder(ctx, path, rep)
		if tc.branch != "" && f.g.ready() && tc.branch != f.g.defaultName {
			tip = f.g.branchState(ctx, tc.branch)
			out.add(branchFinding(tc, tip, f.g.baseName()))
		}
		if tc.prRef != "" {
			if pr := c.prOf(f); pr != nil {
				out.add(pr.finding(ctx, tc))
			}
		}
	}
	out.add(staleFinding(n, tip, c.o, tc.mk))
	return out.list
}

// folderRemovedFinding: the target carries a branch or a pull request, but
// its folder is off the bench, so neither can be checked.
func folderRemovedFinding(tc targetCtx, path string) (Finding, bool) {
	var what string
	switch {
	case tc.branch != "" && tc.prRef != "":
		what = fmt.Sprintf("branch %s and pull request %s are", tc.branch, tc.prRef)
	case tc.branch != "":
		what = fmt.Sprintf("branch %s is", tc.branch)
	case tc.prRef != "":
		what = fmt.Sprintf("pull request %s is", tc.prRef)
	default:
		return Finding{}, false
	}
	return tc.mk(KindFolderRemoved, fmt.Sprintf("folder removed: %s is no longer on the bench, so its %s not checked", path, what),
		fixFolderRemoved), true
}

// skipped: a dismissed target, or one done long ago, is history.
func skipped(n db.BoardNode, now time.Time) bool {
	st := n.Target.Status
	return st == "dismissed" || (st == "done" && !recentlyMoved(n, now, DoneRecentWindow))
}

func (c *checker) contextOf(n db.BoardNode, folder string) targetCtx {
	t := n.Target
	branch, prRef := strings.TrimSpace(t.Branch), strings.TrimSpace(t.PR)
	return targetCtx{
		status: t.Status, branch: branch, prRef: prRef, parent: len(n.Children) > 0,
		sharedRef: (branch != "" && c.openRefs[refKey(folder, "branch", branch)]) ||
			(prRef != "" && c.openRefs[refKey(folder, "pr", strings.TrimPrefix(prRef, "#"))]),
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
	fixPRClosed      = "the pull request was closed without a merge: reopen or replace it (update_target pr), or move the target to blocked/dismissed"
	fixFolderRemoved = "its folder was removed from the bench: if the work moved to another folder of the bench, " +
		"set it (update_target folder); if the work is gone, clear its branch/pr (update_target branch \"\", pr \"\")"
	fixStale = "if it is finished, move it on (in_review / done); if it waits on someone, set it blocked and say why in add_comment"
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
