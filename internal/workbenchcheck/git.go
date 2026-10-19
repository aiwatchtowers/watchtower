package workbenchcheck

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/gitbin"
)

// squashWindow is how many of the non-merge commits the default branch
// gained since a branch forked a squash merge is looked for in (by patch id).
const squashWindow = 200

// noGitNote is the check's note when no git binary exists outside the
// macOS /usr/bin/git shim.
const noGitNote = "git is not available (no Command Line Tools); branch checks skipped"

// noGitPRNote: without git the pull request states are not read either.
const noGitPRNote = "git is not available; pull request states not checked"

// locateGit finds git; a variable so a test can take git away.
var locateGit = gitbin.Locate

// ExecRunner runs a real process through gitbin.Exec, which keeps git and gh
// non-interactive and lock-free: the check only reads. "git" is the binary
// gitbin locates — never a PATH lookup, never the /usr/bin/git shim, whose
// install dialog would pop in the owner's face; with none found it runs
// nothing and returns gitbin.ErrUnavailable. git runs with the folder's
// fsmonitor command, hooks, signature checks and filter drivers off
// (gitbin.ReadArgsIn): the
// check runs in the background on a folder Watchtower does not vouch for.
func ExecRunner(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
	bin := name
	if name == "git" {
		located, ok := locateGit()
		if !ok {
			return nil, -1, gitbin.ErrUnavailable
		}
		bin = located
	}
	argv := args
	if name == "git" {
		var err error
		if argv, err = gitbin.ReadArgsIn(ctx, bin, dir, args...); err != nil {
			return nil, -1, err
		}
	}
	stdout, stderr, err := gitbin.Exec(ctx, dir, stdin, bin, argv...)
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return stdout, 0, nil
	case errors.As(err, &exitErr):
		return stdout, exitErr.ExitCode(), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, stderr)
	default:
		return nil, -1, err
	}
}

// insideRepository reports whether dir or one of its parents holds a .git
// entry (a directory, or a linked worktree's gitdir file); no process runs.
func insideRepository(dir string) bool { return gitbin.InsideRepository(dir) }

// gitState is what the check knows about the folder's repository.
type gitState struct {
	o           Options
	workTree    bool
	noGit       bool     // inside a repository, but no git binary was found
	defaultName string   // e.g. "main"
	bases       []string // resolved commits of origin/<default> and <default>, whichever exist
	baseLabel   string   // e.g. "origin/main"
	notes       []string
	// guardNote is set once when a file-content read was refused because
	// the folder's filter drivers could not be switched off
	// (gitbin.ErrFilterGuard): Check names it instead of degrading silently.
	guardNote string
	// refs is every local and origin branch read by one for-each-ref
	// (refsRead: tried once); nil when that read failed, and each branch is
	// then resolved on its own.
	refs     map[string]refInfo
	refsRead bool
	// tips memoises branchState: plan tasks share their feature's branch, so
	// a board names far fewer branches than it has targets.
	tips map[string]branchTip
	// firstParent[base] is base's first-parent line, read once by one
	// rev-list; nil when that read failed (onFirstParentLine then asks git
	// per commit).
	firstParent map[string]map[string]bool
	// commitPatch is each default-branch commit's patch id ("" for an empty
	// diff), kept across branches: their squash windows mostly overlap.
	commitPatch map[string]string
}

// refInfo is one branch ref as the batch read saw it.
type refInfo struct {
	sha       string // "" when the ref does not name a commit: resolved on its own
	committed time.Time
	// ahead[i] / behind[i] count the commits the ref has that bases[i]
	// lacks, and the other way round; -1 when not known. A git before 2.41
	// has no %(ahead-behind): ahead is then 0 for a ref bases[i] contains
	// (for-each-ref --merged) and -1 otherwise, behind always -1.
	ahead, behind []int
}

func newGitState(ctx context.Context, o Options) *gitState {
	g := &gitState{o: o}
	// No git call at all unless the folder is inside a repository, so a
	// plain folder never spawns git; inside one, ExecRunner runs the git
	// gitbin located, never the /usr/bin/git shim's install dialog.
	if !insideRepository(o.Folder) {
		g.notes = append(g.notes, "the folder is not a git work tree; branch checks skipped")
		return g
	}
	out, _, err := g.git(ctx, "rev-parse", "--is-inside-work-tree")
	if ctx.Err() != nil {
		return g // Check reports the deadline; no conclusion from a cut call
	}
	if errors.Is(err, gitbin.ErrUnavailable) {
		g.noGit = true
		g.notes = append(g.notes, noGitNote)
		return g
	}
	if err != nil || strings.TrimSpace(out) != "true" {
		g.notes = append(g.notes, "the folder is not a git work tree; branch checks skipped")
		return g
	}
	g.workTree = true
	g.defaultName = g.findDefaultName(ctx)
	if ctx.Err() != nil {
		return g
	}
	if g.defaultName == "" {
		g.notes = append(g.notes, "no default branch found (origin/HEAD, main or master); branch checks skipped")
		return g
	}
	for _, ref := range []string{"refs/remotes/origin/" + g.defaultName, "refs/heads/" + g.defaultName} {
		if sha := g.resolve(ctx, ref); sha != "" && !slices.Contains(g.bases, sha) {
			if g.baseLabel == "" {
				g.baseLabel = strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "refs/heads/")
			}
			g.bases = append(g.bases, sha)
		}
	}
	if ctx.Err() != nil {
		return g
	}
	if len(g.bases) == 0 {
		g.notes = append(g.notes, fmt.Sprintf("default branch %s could not be resolved locally or on origin (renamed? run `git remote set-head origin -a`); branch checks skipped", g.defaultName))
	}
	return g
}

func (g *gitState) ready() bool { return len(g.bases) > 0 }

// Repository is a folder's git state read the way Check reads it, for
// branch merge detection outside the check (the session report's PR cache).
type Repository struct{ g *gitState }

// OpenRepository probes folder's repository like Check does: no git process
// outside a repository, git located through gitbin. run nil = ExecRunner.
func OpenRepository(ctx context.Context, folder string, run Runner) *Repository {
	if run == nil {
		run = ExecRunner
	}
	return &Repository{g: newGitState(ctx, Options{Folder: folder, Run: run})}
}

// GitMissing reports that the folder is inside a repository but no git
// binary exists outside the /usr/bin/git shim (gh, which runs git from PATH,
// must not run either).
func (r *Repository) GitMissing() bool { return r.g.noGit }

// Notes say why branch checks are skipped, if they are.
func (r *Repository) Notes() []string { return r.g.notes }

// BranchMerge is a branch's merge state against the default branch.
type BranchMerge int

const (
	BranchUnknown   BranchMerge = iota // a git call failed, no default branch, or the branch is the default one
	BranchMissing                      // exists neither locally nor on origin
	BranchMerged                       // its work is in the default branch (merge, fast-forward, cherry, squash)
	BranchNotMerged                    // every base says its work is not in it
)

// BranchMerge runs the check's merge detection on branch.
func (r *Repository) BranchMerge(ctx context.Context, branch string) BranchMerge {
	if branch == "" || branch == r.g.defaultName {
		return BranchUnknown
	}
	tip := r.g.branchState(ctx, branch)
	switch {
	case tip.state == tipMissing:
		return BranchMissing
	case tip.state != tipFound:
		return BranchUnknown
	case tip.merge == merged:
		return BranchMerged
	case tip.merge == notMerged:
		return BranchNotMerged
	}
	return BranchUnknown
}

func (g *gitState) baseName() string { return g.baseLabel }

func (g *gitState) git(ctx context.Context, args ...string) (string, int, error) {
	out, code, err := g.o.Run(ctx, g.o.Folder, nil, "git", args...)
	if errors.Is(err, gitbin.ErrFilterGuard) && g.guardNote == "" {
		g.guardNote = "squash-merge checks skipped: " + err.Error()
	}
	return string(out), code, err
}

// findDefaultName is origin/HEAD's branch, else main, else master.
func (g *gitState) findDefaultName(ctx context.Context) string {
	if out, _, err := g.git(ctx, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"); err == nil {
		if name := strings.TrimPrefix(strings.TrimSpace(out), "refs/remotes/origin/"); name != "" {
			return name
		}
	}
	for _, name := range []string{"main", "master"} {
		if g.resolve(ctx, "refs/remotes/origin/"+name) != "" || g.resolve(ctx, "refs/heads/"+name) != "" {
			return name
		}
	}
	return ""
}

// resolve returns ref's commit id, or "" when it does not exist.
func (g *gitState) resolve(ctx context.Context, ref string) string {
	out, _, err := g.git(ctx, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// verdict is a merge check's answer; unknown when a git call failed, so an
// error is never read as "not merged" (or as "merged").
type verdict int

const (
	unknown verdict = iota
	merged
	notMerged
)

// tipState says whether a linked branch was found.
type tipState int

const (
	tipUnknown tipState = iota // a git call failed: no conclusion
	tipMissing                 // exists neither locally nor on origin
	tipFound
)

// branchTip is a linked branch's state against the default branch.
type branchTip struct {
	state     tipState
	merge     verdict   // merged into any base; notMerged only when every base says so
	ahead     int       // commits not in the base (the smallest over the bases)
	committed time.Time // its newest commit's time
}

// tipOf resolves ref to its commit; "" with known=true when ref does not
// exist, known=false when git failed otherwise.
func (g *gitState) tipOf(ctx context.Context, ref string) (sha string, known bool) {
	out, code, err := g.git(ctx, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	switch {
	case err == nil:
		return strings.TrimSpace(out), true
	case code == 1 && ctx.Err() == nil: // --quiet: a missing ref exits 1
		return "", true
	}
	return "", false
}

// branchRefs reads every local and origin branch — its commit, commit time
// and, where git has %(ahead-behind), its distance from each base — in one
// for-each-ref, at most once per check. nil when the read failed.
func (g *gitState) branchRefs(ctx context.Context) map[string]refInfo {
	if g.refsRead {
		return g.refs
	}
	g.refsRead = true
	format := "%(objecttype) %(refname) %(objectname) %(committerdate:unix)"
	for _, base := range g.bases {
		format += " %(ahead-behind:" + base + ")"
	}
	out, _, err := g.git(ctx, "for-each-ref", "--format="+format, "refs/heads", "refs/remotes/origin")
	counts := err == nil
	if err != nil && ctx.Err() == nil {
		// A git before 2.41 refuses the ahead-behind atom.
		out, _, err = g.git(ctx, "for-each-ref", "--format=%(objecttype) %(refname) %(objectname) %(committerdate:unix)",
			"refs/heads", "refs/remotes/origin")
	}
	if err != nil {
		return nil
	}
	refs := map[string]refInfo{}
	for line := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		info := refInfo{ahead: unknownCounts(len(g.bases)), behind: unknownCounts(len(g.bases))}
		if f[0] == "commit" {
			info.sha = f[2]
			if sec, err := strconv.ParseInt(f[3], 10, 64); err == nil {
				info.committed = time.Unix(sec, 0)
			}
		}
		if counts && len(f) == 4+2*len(g.bases) {
			for i := range g.bases {
				a, errA := strconv.Atoi(f[4+2*i])
				b, errB := strconv.Atoi(f[5+2*i])
				if errA == nil && errB == nil {
					info.ahead[i], info.behind[i] = a, b
				}
			}
		}
		refs[f[1]] = info
	}
	if !counts {
		g.markMerged(ctx, refs)
	}
	g.refs = refs
	return refs
}

func unknownCounts(n int) []int {
	c := make([]int, n)
	for i := range c {
		c[i] = -1
	}
	return c
}

// markMerged sets ahead 0 for every ref a base contains, one for-each-ref
// --merged per base; a failed listing leaves that base's counts unknown.
func (g *gitState) markMerged(ctx context.Context, refs map[string]refInfo) {
	for i, base := range g.bases {
		out, _, err := g.git(ctx, "for-each-ref", "--merged="+base, "--format=%(refname)", "refs/heads", "refs/remotes/origin")
		if err != nil {
			continue
		}
		for ref := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
			if info, ok := refs[ref]; ok {
				info.ahead[i] = 0
			}
		}
	}
}

// lookup is ref from the batch read, else resolved on its own (tipOf):
// info.sha "" with known=true when ref does not exist. A name the batch read
// lists only in another case is resolved on its own too: on a
// case-insensitive file system git resolves a loose ref by any case.
func (g *gitState) lookup(ctx context.Context, ref string) (info refInfo, known bool) {
	if refs := g.branchRefs(ctx); refs != nil {
		info, ok := refs[ref]
		if ok && info.sha != "" {
			return info, true
		}
		if !ok && !hasFoldedKey(refs, ref) {
			return refInfo{}, true
		}
	}
	sha, known := g.tipOf(ctx, ref)
	if sha != "" {
		n := len(g.bases)
		return refInfo{sha: sha, committed: g.commitTime(ctx, sha), ahead: unknownCounts(n), behind: unknownCounts(n)}, known
	}
	return refInfo{}, known
}

func hasFoldedKey(refs map[string]refInfo, ref string) bool {
	for k := range refs {
		if strings.EqualFold(k, ref) {
			return true
		}
	}
	return false
}

// branchState is the branch's state, read once per check (a cut-short read
// is not kept).
func (g *gitState) branchState(ctx context.Context, branch string) branchTip {
	if !g.ready() {
		return branchTip{}
	}
	if tip, ok := g.tips[branch]; ok {
		return tip
	}
	tip := g.readBranch(ctx, branch)
	if ctx.Err() == nil {
		if g.tips == nil {
			g.tips = map[string]branchTip{}
		}
		g.tips[branch] = tip
	}
	return tip
}

func (g *gitState) readBranch(ctx context.Context, branch string) branchTip {
	local := true
	info, known := g.lookup(ctx, "refs/heads/"+branch)
	if known && info.sha == "" {
		local = false
		info, known = g.lookup(ctx, "refs/remotes/origin/"+branch)
	}
	switch {
	case !known:
		return branchTip{}
	case info.sha == "":
		return branchTip{state: tipMissing}
	}
	sha := info.sha
	tip := branchTip{state: tipFound, ahead: -1, committed: info.committed}
	allNotMerged := true
	var rl branchReflog
	for i, base := range g.bases {
		v, ahead := g.mergedInto(ctx, branch, sha, base, local, &rl, info.ahead[i], info.behind[i])
		if v == merged {
			tip.merge = merged
		}
		allNotMerged = allNotMerged && v == notMerged
		if ahead >= 0 && (tip.ahead < 0 || ahead < tip.ahead) {
			tip.ahead = ahead
		}
	}
	if tip.merge != merged && allNotMerged {
		tip.merge = notMerged
	}
	tip.ahead = max(tip.ahead, 0)
	return tip
}

func (g *gitState) commitTime(ctx context.Context, sha string) time.Time {
	out, _, err := g.git(ctx, "log", "-1", "--format=%ct", sha, "--")
	if err != nil {
		return time.Time{}
	}
	sec, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(sec, 0)
}

// branchReflog is what a local branch's reflog says about its own work.
type branchReflog struct {
	read      bool // the reflog was read (it is read at most once per check)
	ok        bool // reading it succeeded
	tipHere   bool // its current tip was made on the branch: a commit or a cherry-pick
	ownCommit bool // some commit was ever made on the branch
}

// reflogOf reads branch's reflog once. A tip made on the branch itself,
// once the default branch contains it, is merged work; a branch just cut,
// rebased or reset onto the default branch with no commit of its own is not.
func (g *gitState) reflogOf(ctx context.Context, branch, sha string) branchReflog {
	out, _, err := g.git(ctx, "reflog", "show", "--format=%H %gs", "refs/heads/"+branch, "--")
	r := branchReflog{read: true, ok: err == nil}
	if err != nil {
		return r
	}
	for line := range strings.SplitSeq(out, "\n") {
		id, subject, _ := strings.Cut(line, " ")
		if strings.HasPrefix(subject, "commit") || strings.HasPrefix(subject, "cherry-pick") {
			r.ownCommit = true
			r.tipHere = r.tipHere || id == sha
		}
	}
	return r
}

// mergedInto reports whether commit sha's work is in base, and how many of
// sha's commits base lacks (-1 when unknown).
//
// A tip base already contains (ahead 0) is the same shape for a branch
// merged by a fast-forward and one just cut from the default branch with no
// commits of its own; containedVerdict tells them apart. A branch known
// only on origin has no reflog, so it counts as merged only when its tip
// sits off base's first-parent line — a commit-less branch pushed from a
// merged feature's tip reads as merged there (accepted: such a branch is
// rarely only on origin).
//
// A tip base lacks (ahead > 0) is merged when every one of its commits is
// already in base by patch id (`git cherry`: a rebase merge, a cherry-pick)
// or when its whole diff matches one commit base gained since the fork (a
// squash merge); not merged only when both checks ran and said no.
//
// ahead and behind are the batch read's counts (base..sha, sha..base), -1
// when not known: then they are counted here.
func (g *gitState) mergedInto(ctx context.Context, branch, sha, base string, local bool, rl *branchReflog, ahead, behind int) (verdict, int) {
	if ahead < 0 {
		var ok bool
		if ahead, ok = g.count(ctx, base+".."+sha); !ok {
			return unknown, -1
		}
	}
	if ahead == 0 {
		return g.containedVerdict(ctx, branch, sha, base, local, rl), 0
	}
	cherry := g.cherryMerged(ctx, sha, base, behind)
	if cherry == merged {
		return merged, ahead
	}
	squash := g.squashMerged(ctx, sha, base)
	switch {
	case squash == merged:
		return merged, ahead
	case cherry == notMerged && squash == notMerged:
		return notMerged, ahead
	}
	return unknown, ahead
}

// count is `git rev-list --count <revs>`; ok false when git failed.
func (g *gitState) count(ctx context.Context, revs string) (int, bool) {
	out, _, err := g.git(ctx, "rev-list", "--count", revs)
	if err != nil {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(out))
	return n, err == nil
}

// containedVerdict decides a branch whose tip base already contains. Merged
// when a merge commit brought the tip in (it sits off base's first-parent
// line) — for a local branch only if a commit was ever made on it, so a
// commit-less branch stacked on merged work is not — or when a local
// branch's tip was itself committed on the branch (a fast-forward).
func (g *gitState) containedVerdict(ctx context.Context, branch, sha, base string, local bool, rl *branchReflog) verdict {
	if local && !rl.read {
		*rl = g.reflogOf(ctx, branch, sha)
	}
	if local && rl.ok && rl.tipHere {
		return merged
	}
	onLine, ok := g.onFirstParentLine(ctx, sha, base)
	switch {
	case !ok || (local && !rl.ok):
		return unknown
	case onLine:
		return notMerged
	case local:
		return verdictOf(rl.ownCommit)
	}
	return merged
}

func verdictOf(b bool) verdict {
	if b {
		return merged
	}
	return notMerged
}

// onFirstParentLine: sha is an ancestor of base; it is on base's first-parent
// line iff base~k is sha, where k counts the first-parent commits of base
// that sha cannot reach — the same as sha being on base's first-parent line
// as one rev-list lists it, which is read once per base. ok is false when
// git failed.
func (g *gitState) onFirstParentLine(ctx context.Context, sha, base string) (onLine, ok bool) {
	if line := g.firstParentLine(ctx, base); line != nil {
		return line[sha], true
	}
	out, _, err := g.git(ctx, "rev-list", "--first-parent", "--count", sha+".."+base)
	if err != nil {
		return false, false
	}
	at, _, err := g.git(ctx, "rev-parse", "--verify", "--quiet", base+"~"+strings.TrimSpace(out))
	if err != nil {
		return false, false
	}
	return strings.TrimSpace(at) == sha, true
}

// firstParentLine is base's first-parent commits, read at most once per
// check; nil when the read failed.
func (g *gitState) firstParentLine(ctx context.Context, base string) map[string]bool {
	if line, read := g.firstParent[base]; read {
		return line
	}
	if g.firstParent == nil {
		g.firstParent = map[string]map[string]bool{}
	}
	out, _, err := g.git(ctx, "rev-list", "--first-parent", base)
	if err != nil {
		if ctx.Err() == nil {
			g.firstParent[base] = nil
		}
		return nil
	}
	line := map[string]bool{}
	for sha := range strings.SplitSeq(strings.TrimSpace(out), "\n") {
		line[sha] = true
	}
	g.firstParent[base] = line
	return line
}

// cherryMerged: `git cherry base sha` marks each of sha's commits "-" when an
// equivalent patch is already in base. It patch-ids every commit base gained
// since the fork, so past squashWindow of them it is not run (unknown).
// behind is that count when already known, else -1.
func (g *gitState) cherryMerged(ctx context.Context, sha, base string, behind int) verdict {
	if behind < 0 {
		var ok bool
		if behind, ok = g.count(ctx, sha+".."+base); !ok {
			return unknown
		}
	}
	if behind > squashWindow {
		return unknown
	}
	out, _, err := g.git(ctx, "cherry", base, sha)
	if err != nil {
		return unknown
	}
	lines := strings.Fields(out)
	if len(lines) == 0 {
		return unknown
	}
	for i := 0; i < len(lines); i += 2 {
		if lines[i] != "-" {
			return notMerged
		}
	}
	return merged
}

// squashMerged looks for the branch's whole diff, by patch id, among the
// non-merge commits base gained since the two forked (at most squashWindow
// of them, newest first).
func (g *gitState) squashMerged(ctx context.Context, sha, base string) verdict {
	mb, _, err := g.git(ctx, "merge-base", base, sha)
	if err != nil {
		return unknown
	}
	fork := strings.TrimSpace(mb)
	// -U0 on both sides: patch-id hashes context lines, so a line main
	// changed next to the branch's hunks would make an otherwise identical
	// squash differ.
	diff, _, err := g.git(ctx, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "-U0", fork, sha)
	if err != nil {
		return unknown
	}
	if strings.TrimSpace(diff) == "" {
		return notMerged
	}
	want, ok := g.patchIDsOf(ctx, []byte(diff))
	if !ok || len(want) != 1 {
		return unknown
	}
	window, _, err := g.git(ctx, "rev-list", "--no-merges", "--max-count="+strconv.Itoa(squashWindow), fork+".."+base)
	if err != nil {
		return unknown
	}
	commits := strings.Fields(window)
	if !g.readPatches(ctx, commits) {
		return unknown
	}
	for id := range want {
		return verdictOf(slices.ContainsFunc(commits, func(c string) bool { return g.commitPatch[c] == id }))
	}
	return unknown
}

// readPatches fills commitPatch for the commits not read yet, with one
// log -p over them.
func (g *gitState) readPatches(ctx context.Context, commits []string) bool {
	if g.commitPatch == nil {
		g.commitPatch = map[string]string{}
	}
	var missing []string
	for _, c := range commits {
		if _, ok := g.commitPatch[c]; !ok {
			missing = append(missing, c)
		}
	}
	if len(missing) == 0 {
		return true
	}
	args := append([]string{"log", "-p", "-U0", "--no-walk=unsorted", "--no-color", "--no-ext-diff", "--no-textconv",
		"--ignore-submodules=all", "--format=commit %H"}, missing...)
	log, _, err := g.git(ctx, args...)
	if err != nil {
		return false
	}
	out, ok := g.patchIDLines(ctx, []byte(log))
	if !ok {
		return false
	}
	found := map[string]string{}
	for _, f := range out {
		if len(f) == 2 {
			found[f[1]] = f[0]
		}
	}
	for _, c := range missing {
		g.commitPatch[c] = found[c]
	}
	return true
}

// patchIDsOf runs `git patch-id --stable` over a diff.
func (g *gitState) patchIDsOf(ctx context.Context, patch []byte) (map[string]bool, bool) {
	lines, ok := g.patchIDLines(ctx, patch)
	if !ok {
		return nil, false
	}
	ids := map[string]bool{}
	for _, f := range lines {
		ids[f[0]] = true
	}
	return ids, true
}

// patchIDLines runs `git patch-id --stable` over a diff or a log -p stream:
// one "<patch id> <commit id>" line per patch.
func (g *gitState) patchIDLines(ctx context.Context, patch []byte) ([][]string, bool) {
	if len(bytes.TrimSpace(patch)) == 0 {
		return nil, true
	}
	out, _, err := g.o.Run(ctx, g.o.Folder, patch, "git", "patch-id", "--stable")
	if err != nil {
		return nil, false
	}
	var lines [][]string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if f := strings.Fields(sc.Text()); len(f) > 0 {
			lines = append(lines, f)
		}
	}
	return lines, true
}
