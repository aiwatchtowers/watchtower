package projectcheck

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

// squashWindow is how many of the non-merge commits the default branch
// gained since a branch forked a squash merge is looked for in (by patch id).
const squashWindow = 200

// ExecRunner runs a real process. The environment keeps git and gh
// non-interactive and lock-free: the check only reads.
func ExecRunner(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
	c := exec.CommandContext(ctx, name, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GH_PROMPT_DISABLED=1", "LC_ALL=C")
	c.WaitDelay = time.Second
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	c.Stdout, c.Stderr = &stdout, &stderr
	err := c.Run()
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return stdout.Bytes(), 0, nil
	case errors.As(err, &exitErr):
		return stdout.Bytes(), exitErr.ExitCode(), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, bytes.TrimSpace(stderr.Bytes()))
	default:
		return nil, -1, err
	}
}

// insideRepository reports whether dir or one of its parents holds a .git
// entry (a directory, or a linked worktree's gitdir file).
func insideRepository(dir string) bool {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return false
	}
	for cur := abs; ; cur = filepath.Dir(cur) {
		if _, err := os.Lstat(filepath.Join(cur, ".git")); err == nil {
			return true
		}
		if filepath.Dir(cur) == cur {
			return false
		}
	}
}

// gitState is what the check knows about the folder's repository.
type gitState struct {
	o           Options
	workTree    bool
	defaultName string   // e.g. "main"
	bases       []string // resolved commits of origin/<default> and <default>, whichever exist
	baseLabel   string   // e.g. "origin/main"
	notes       []string
}

func newGitState(ctx context.Context, o Options) *gitState {
	g := &gitState{o: o}
	// No git call at all unless the folder is inside a repository: on a Mac
	// without the developer tools, /usr/bin/git itself would pop an install
	// dialog in the owner's face.
	if !insideRepository(o.Folder) {
		g.notes = append(g.notes, "the folder is not a git work tree; branch checks skipped")
		return g
	}
	out, _, err := g.git(ctx, "rev-parse", "--is-inside-work-tree")
	if ctx.Err() != nil {
		return g // Check reports the deadline; no conclusion from a cut call
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

func (g *gitState) baseName() string { return g.baseLabel }

func (g *gitState) git(ctx context.Context, args ...string) (string, int, error) {
	out, code, err := g.o.Run(ctx, g.o.Folder, nil, "git", args...)
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

func (g *gitState) branchState(ctx context.Context, branch string) branchTip {
	if !g.ready() {
		return branchTip{}
	}
	local := true
	sha, known := g.tipOf(ctx, "refs/heads/"+branch)
	if known && sha == "" {
		local = false
		sha, known = g.tipOf(ctx, "refs/remotes/origin/"+branch)
	}
	switch {
	case !known:
		return branchTip{}
	case sha == "":
		return branchTip{state: tipMissing}
	}
	tip := branchTip{state: tipFound, ahead: -1, committed: g.commitTime(ctx, sha)}
	allNotMerged := true
	var rl branchReflog
	for _, base := range g.bases {
		v, ahead := g.mergedInto(ctx, branch, sha, base, local, &rl)
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
	for _, line := range strings.Split(out, "\n") {
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
func (g *gitState) mergedInto(ctx context.Context, branch, sha, base string, local bool, rl *branchReflog) (verdict, int) {
	out, _, err := g.git(ctx, "rev-list", "--count", base+".."+sha)
	if err != nil {
		return unknown, -1
	}
	ahead, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil {
		return unknown, -1
	}
	if ahead == 0 {
		return g.containedVerdict(ctx, branch, sha, base, local, rl), 0
	}
	cherry := g.cherryMerged(ctx, sha, base)
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
// that sha cannot reach. ok is false when git failed.
func (g *gitState) onFirstParentLine(ctx context.Context, sha, base string) (onLine, ok bool) {
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

// cherryMerged: `git cherry base sha` marks each of sha's commits "-" when an
// equivalent patch is already in base. It patch-ids every commit base gained
// since the fork, so past squashWindow of them it is not run (unknown).
func (g *gitState) cherryMerged(ctx context.Context, sha, base string) verdict {
	n, _, err := g.git(ctx, "rev-list", "--count", sha+".."+base)
	if count, convErr := strconv.Atoi(strings.TrimSpace(n)); err != nil || convErr != nil || count > squashWindow {
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
	diff, _, err := g.git(ctx, "diff", "--no-color", "--no-ext-diff", "-U0", fork, sha)
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
	log, _, err := g.git(ctx, "log", "-p", "-U0", "--no-merges", "--no-color", "--no-ext-diff",
		"--max-count="+strconv.Itoa(squashWindow), fork+".."+base)
	if err != nil {
		return unknown
	}
	got, ok := g.patchIDsOf(ctx, []byte(log))
	if !ok {
		return unknown
	}
	for id := range want {
		return verdictOf(got[id])
	}
	return unknown
}

// patchIDsOf runs `git patch-id --stable` over a diff or a log -p stream.
func (g *gitState) patchIDsOf(ctx context.Context, patch []byte) (map[string]bool, bool) {
	ids := map[string]bool{}
	if len(bytes.TrimSpace(patch)) == 0 {
		return ids, true
	}
	out, _, err := g.o.Run(ctx, g.o.Folder, patch, "git", "patch-id", "--stable")
	if err != nil {
		return nil, false
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if f := strings.Fields(sc.Text()); len(f) > 0 {
			ids[f[0]] = true
		}
	}
	return ids, true
}
