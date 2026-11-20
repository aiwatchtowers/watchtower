package sessioncleanup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// buildMarker is SwiftPM's marker file (buildKinds).
const buildMarker = "workspace-state.json"

// trashIn lists the trash folders (<name><trashInfix>…) in dir.
func trashIn(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	for _, k := range buildKinds {
		m, err := filepath.Glob(filepath.Join(dir, k.name+trashInfix+"*"))
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, m...)
	}
	return out
}

// markedTrash makes a leftover of an interrupted prune at dir: the prune's
// marker and the build folder it moved in, half deleted.
func markedTrash(t *testing.T, dir string) string {
	t.Helper()
	name, _, _ := strings.Cut(filepath.Base(dir), trashInfix)
	writeFile(t, filepath.Join(dir, name, "half"), "x\n")
	writeFile(t, filepath.Join(dir, trashMarker), trashMarkerBody)
	return dir
}

// swiftBuild makes a SwiftPM build folder at dir (its workspace-state.json
// and an artefact) and returns dir.
func swiftBuild(t *testing.T, dir string) string {
	t.Helper()
	writeFile(t, filepath.Join(dir, buildMarker), "{}\n")
	writeFile(t, filepath.Join(dir, "debug", "App"), "binary\n")
	return dir
}

// endSession marks the test session finished, as finish_session does.
func (f *fixture) endSession() {
	f.store.activity = append(f.store.activity, SessionActivity{ID: testSession, WorkbenchID: testWorkbench,
		Title: "the session", Finished: true})
}

// unpushedWithBuild is a worktree of the session with an unpushed commit,
// an ignored SwiftPM build folder at its root and one in a package folder.
func (f *fixture) unpushedWithBuild() (root string, builds []string) {
	f.t.Helper()
	root = f.worktree("wt", "feat/x")
	f.commit(root, ".gitignore", ".build/\n")
	f.commit(root, "Pkg/Package.swift", "// swift-tools-version:5.10\n")
	f.record(root, "feat/x")
	return root, []string{swiftBuild(f.t, filepath.Join(root, ".build")),
		swiftBuild(f.t, filepath.Join(root, "Pkg", ".build"))}
}

// TestProj18_EndedSessionDropsKeptWorktreesBuild (#2131, ask #1695): an
// apply of a finished session that names no item keeps the worktree with
// unpushed work — and every file of it but the SwiftPM build folders, which
// go; the item stays a plain keep, and the summary says so.
func TestProj18_EndedSessionDropsKeptWorktreesBuild(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, builds := f.unpushedWithBuild()
	writeFile(t, filepath.Join(root, "notes.txt"), "untracked\n")
	writeFile(t, filepath.Join(root, "build", "keep.txt"), "not SwiftPM's\n")
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonUncommittedChanges, false)
	if it.Error != "" || it.BuildError != "" {
		t.Fatalf("errors: %q / %q", it.Error, it.BuildError)
	}
	slices.Sort(it.BuildsRemoved)
	want := slices.Clone(builds)
	slices.Sort(want)
	if !slices.Equal(it.BuildsRemoved, want) {
		t.Fatalf("builds removed = %v, want %v", it.BuildsRemoved, want)
	}
	for _, b := range builds {
		if exists(b) || len(trashIn(t, filepath.Dir(b))) > 0 {
			t.Fatalf("%s is still there", b)
		}
	}
	for _, kept := range []string{"notes.txt", "Pkg/Package.swift", "build/keep.txt", ".gitignore"} {
		if !exists(filepath.Join(root, kept)) {
			t.Fatalf("%s was removed", kept)
		}
	}
	if !f.listsWorktree(root) || !f.branchExists("feat/x") {
		t.Fatal("the worktree or its branch went")
	}
	if !strings.Contains(res.Summary, "build output removed from 1 kept worktree") {
		t.Fatalf("summary %q", res.Summary)
	}
}

// TestProj18_BuildStaysUnlessTheSessionEndedAndNothingIsNamed: a session
// still working, an apply naming items, an apply without PruneBuilds and an
// agent's own apply (a caller session) all leave the build folder.
func TestProj18_BuildStaysUnlessTheSessionEndedAndNothingIsNamed(t *testing.T) {
	t.Parallel()
	for name, tc := range map[string]struct {
		ended bool
		req   Request
		only  []string
	}{
		"session not ended": {req: Request{PruneBuilds: true}},
		"no PruneBuilds":    {ended: true},
		"items named":       {ended: true, req: Request{PruneBuilds: true}, only: []string{"branch:none"}},
		"agent's own apply": {ended: true, req: Request{PruneBuilds: true, CallerSessionID: testSession}},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			_, builds := f.unpushedWithBuild()
			if tc.ended {
				f.endSession()
			}
			res := f.apply(tc.req, tc.only, nil)
			for _, it := range res.Items {
				if len(it.BuildsRemoved) > 0 {
					t.Fatalf("%s: builds removed %v", it.Key, it.BuildsRemoved)
				}
			}
			for _, b := range builds {
				if !exists(filepath.Join(b, buildMarker)) {
					t.Fatalf("%s went", b)
				}
			}
		})
	}
}

// TestProj18_BuildOfAWorktreeInUseStays: a process in the worktree (an
// orphan running the build's own binary included), a live session working
// in it, a lock or a rebase in progress keep its build folder.
func TestProj18_BuildOfAWorktreeInUseStays(t *testing.T) {
	t.Parallel()
	for name, setup := range map[string]func(f *fixture, root, build string) Request{
		"a shell in it": func(f *fixture, root, _ string) Request {
			f.procs.list = []Proc{{PID: 4242, PPID: 77, UID: os.Getuid(), Start: "s", Exe: "/bin/zsh", Cwd: root}}
			return Request{}
		},
		"an orphan of the build": func(f *fixture, _, build string) Request {
			f.procs.list = []Proc{{PID: 4243, PPID: 1, UID: os.Getuid(), Start: "s",
				Exe: filepath.Join(build, "debug", "App"), Cwd: "/"}}
			return Request{}
		},
		"a process whose cwd is unknown": func(f *fixture, _, _ string) Request {
			f.procs.list = []Proc{{PID: 4244, PPID: 77, UID: os.Getuid(), Start: "s", Exe: "/bin/zsh"}}
			return Request{}
		},
		"its live terminal works in it": func(f *fixture, root, _ string) Request {
			f.store.activity[0].AgentCwd = root
			return Request{LiveSessions: []int64{testSession}}
		},
		"another session works in it": func(f *fixture, root, _ string) Request {
			f.store.activity = append(f.store.activity, SessionActivity{ID: 99, WorkbenchID: testWorkbench,
				Title: "other", AgentCwd: root, ReportedAt: time.Now()})
			return Request{}
		},
		"locked": func(f *fixture, root, _ string) Request {
			gitIn(t, f.repo, "worktree", "lock", root)
			return Request{}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root, builds := f.unpushedWithBuild()
			// Uncommitted work keeps it first (W4), so the in-use catches
			// below are the prune's own.
			writeFile(t, filepath.Join(root, "notes.txt"), "untracked\n")
			f.endSession()
			req := setup(f, root, builds[0])
			req.PruneBuilds = true
			res := f.apply(req, nil, nil)
			it := findItem(t, res.Plan, "worktree:"+root)
			if it.Action != ActionKeep || len(it.BuildsRemoved) > 0 {
				t.Fatalf("item %+v", it)
			}
			for _, b := range builds {
				if !exists(filepath.Join(b, buildMarker)) {
					t.Fatalf("%s went", b)
				}
			}
		})
	}
}

// TestProj18_BuildPruneTouchesOnlyTheSessionsWorktrees: the main folder's
// build and the build of a worktree the session never saw stay.
func TestProj18_BuildPruneTouchesOnlyTheSessionsWorktrees(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	mainBuild := swiftBuild(t, filepath.Join(f.repo, ".build"))
	other := f.worktree("other", "feat/other")
	f.commit(other, "o.txt", "unpushed\n")
	otherBuild := swiftBuild(t, filepath.Join(other, ".build"))
	f.endSession()

	f.apply(Request{PruneBuilds: true}, nil, nil)
	for _, b := range []string{mainBuild, otherBuild} {
		if !exists(filepath.Join(b, buildMarker)) {
			t.Fatalf("%s went", b)
		}
	}
}

// TestPrune_OnlySwiftPMBuildFolders: a .build without workspace-state.json,
// a symlinked .build (and its target), a tracked .build, a .build that is a
// repository or worktree itself (a .git file or directory in it), the .build
// of a repository nested in the worktree and a .build inside a cache the
// walk skips stay; so do folders named like a leftover that lack the
// prune's marker, the old fixed name included. A marked leftover goes.
func TestPrune_OnlySwiftPMBuildFolders(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt", "feat/x")
	f.record(root, "feat/x")
	tracked := filepath.Join(root, "Tracked", ".build")
	writeFile(t, filepath.Join(tracked, buildMarker), "{}\n")
	gitIn(t, root, "add", "-f", "Tracked/.build/"+buildMarker)
	gitIn(t, root, "commit", "-q", "-m", "tracked build")
	plain := filepath.Join(root, "Plain", ".build")
	writeFile(t, filepath.Join(plain, "x.o"), "obj\n")
	target := swiftBuild(t, filepath.Join(f.base, "elsewhere"))
	if err := os.MkdirAll(filepath.Join(root, "Link"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "Link", ".build")); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "Nested")
	gitIn(t, root, "init", "-q", "Nested")
	nestedBuild := swiftBuild(t, filepath.Join(nested, ".build"))
	repoBuild := swiftBuild(t, filepath.Join(root, "RepoNamedBuild", ".build"))
	gitIn(t, filepath.Dir(repoBuild), "init", "-q", ".build")
	linkedBuild := swiftBuild(t, filepath.Join(root, "LinkedNamedBuild", ".build"))
	writeFile(t, filepath.Join(linkedBuild, ".git"), "gitdir: /elsewhere\n")
	cached := swiftBuild(t, filepath.Join(root, ".swiftpm", "x", ".build"))
	podded := swiftBuild(t, filepath.Join(root, "Pods", ".build"))
	unmarked := filepath.Join(root, "Other", ".build"+trashInfix+"xyz")
	writeFile(t, filepath.Join(unmarked, "mine"), "keep\n")
	oldName := filepath.Join(root, "Old", ".build.removing-by-watchtower")
	writeFile(t, filepath.Join(oldName, "mine"), "keep\n")
	wrongBody := filepath.Join(root, "Wrong", ".build"+trashInfix+"abc")
	writeFile(t, filepath.Join(wrongBody, trashMarker), "something else\n")
	leftover := markedTrash(t, filepath.Join(root, "Pkg", ".build"+trashInfix+"123"))
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := findItem(t, res.Plan, "worktree:"+root)
	if it.Action != ActionKeep || it.BuildError != "" {
		t.Fatalf("item %+v", it)
	}
	if !slices.Equal(it.BuildsRemoved, []string{leftover}) {
		t.Fatalf("builds removed = %v, want only the leftover", it.BuildsRemoved)
	}
	for _, p := range []string{filepath.Join(tracked, buildMarker), filepath.Join(plain, "x.o"),
		filepath.Join(root, "Link", ".build"), filepath.Join(target, buildMarker),
		filepath.Join(nestedBuild, buildMarker), filepath.Join(repoBuild, buildMarker),
		filepath.Join(linkedBuild, buildMarker), filepath.Join(cached, buildMarker),
		filepath.Join(podded, buildMarker), filepath.Join(unmarked, "mine"), filepath.Join(oldName, "mine"),
		filepath.Join(wrongBody, trashMarker)} {
		if !exists(p) {
			t.Fatalf("%s went", p)
		}
	}
	if exists(leftover) {
		t.Fatal("the leftover is still there")
	}
}

// TestProj18_DerivedDataInTheWorktreeGoes (#2131, controller ruling on
// Q1): an Xcode DerivedData folder a build was pointed at inside a kept
// worktree (its info.plist and Build) goes with the SwiftPM build; one
// without Build, and a file named info.plist alone, stay.
func TestProj18_DerivedDataInTheWorktreeGoes(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, _ := f.unpushedWithBuild()
	derived := filepath.Join(root, "build", "DerivedData")
	writeFile(t, filepath.Join(derived, "info.plist"), "<plist/>\n")
	writeFile(t, filepath.Join(derived, "Build", "Products", "App"), "binary\n")
	partial := filepath.Join(root, "Other", "DerivedData")
	writeFile(t, filepath.Join(partial, "info.plist"), "<plist/>\n")
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := findItem(t, res.Plan, "worktree:"+root)
	if !slices.Contains(it.BuildsRemoved, derived) || exists(derived) {
		t.Fatalf("DerivedData stayed: %+v", it)
	}
	if !exists(filepath.Join(partial, "info.plist")) || len(trashIn(t, filepath.Dir(derived))) > 0 {
		t.Fatal("the partial DerivedData went, or a trash folder is left")
	}
}

// TestPrune_RemovedWorktreeTakesItsBuild: a worktree that can go goes with
// its build folder, as before; nothing is reported as pruned.
func TestPrune_RemovedWorktreeTakesItsBuild(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.commit(root, ".gitignore", ".build/\n")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	swiftBuild(t, filepath.Join(root, ".build"))
	f.record(root, "feat/x")
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if len(it.BuildsRemoved) > 0 || exists(root) {
		t.Fatalf("item %+v, root exists %v", it, exists(root))
	}
}

// TestRemoveBuildDir_UniqueTrashAndMarker: removeBuildDir moves the folder
// onto a fresh trash folder of its own and deletes it; a folder beside it
// that only looks like trash (no marker) is never touched.
func TestRemoveBuildDir_UniqueTrashAndMarker(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	build := swiftBuild(t, filepath.Join(dir, ".build"))
	lookalike := filepath.Join(dir, ".build"+trashInfix+"owner")
	writeFile(t, filepath.Join(lookalike, "precious"), "x\n")
	old := filepath.Join(dir, ".build.removing-by-watchtower")
	writeFile(t, filepath.Join(old, "precious"), "x\n")
	if err := removeBuildDir(build, os.RemoveAll); err != nil {
		t.Fatal(err)
	}
	if exists(build) {
		t.Fatal("the build is still there")
	}
	if got := trashIn(t, dir); !slices.Equal(got, []string{lookalike}) {
		t.Fatalf("trash folders left: %v", got)
	}
	for _, p := range []string{filepath.Join(lookalike, "precious"), filepath.Join(old, "precious")} {
		if !exists(p) {
			t.Fatalf("%s went", p)
		}
	}
}

// TestFindBuildDirs_MarkedTrashOnly: the walk reports a trash-named folder
// only with the prune's marker and body.
func TestFindBuildDirs_MarkedTrashOnly(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	marked := markedTrash(t, filepath.Join(dir, "DerivedData"+trashInfix+"1"))
	writeFile(t, filepath.Join(dir, "DerivedData"+trashInfix+"2", "x"), "y\n")
	found, err := findBuildDirs(context.Background(), dir, time.Minute)
	if err != nil || len(found) != 1 || found[0].path != marked || !found[0].trash {
		t.Fatalf("found %+v, err %v", found, err)
	}
}

// TestFindBuildDirs_OverTheBudgetFails: a walk out of budget finds nothing
// and fails, so nothing is deleted.
func TestFindBuildDirs_OverTheBudgetFails(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	for i := range nestedClockEvery + 1 {
		if err := os.Mkdir(filepath.Join(dir, "d"+strconv.Itoa(i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	swiftBuild(t, filepath.Join(dir, ".build"))
	if found, err := findBuildDirs(context.Background(), dir, -time.Second); err == nil {
		t.Fatalf("found %v without an error", found)
	}
}

// TestPrune_PrunableWorktreeIsSkippedQuietly: a kept worktree whose
// directory is gone has no build to drop and reports no build error.
func TestPrune_PrunableWorktreeIsSkippedQuietly(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, _ := f.unpushedWithBuild()
	if err := os.RemoveAll(root); err != nil {
		t.Fatal(err)
	}
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonUnpushedCommits, false)
	if it.BuildError != "" || len(it.BuildsRemoved) > 0 {
		t.Fatalf("item %+v", it)
	}
}

// flipGit is the real git that runs flip once, at the first `worktree
// list` after the evaluation's: the facts the prune's re-check reads.
type flipGit struct {
	SystemGit
	mu    sync.Mutex
	lists int
	flip  func()
}

func (g *flipGit) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	if slices.Equal(args, []string{"worktree", "list", "--porcelain"}) {
		g.mu.Lock()
		g.lists++
		if g.lists == 2 && g.flip != nil {
			g.flip()
		}
		g.mu.Unlock()
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}

// TestProj18_PruneRechecksOnFreshFacts (#2131, review F2): a worktree the
// evaluation kept only for uncommitted changes keeps its build when the
// facts read right before the prune show it locked, a git operation in
// progress, not the session's any more, a workbench folder, or the home
// directory cannot be told.
func TestProj18_PruneRechecksOnFreshFacts(t *testing.T) {
	t.Parallel()
	for name, flip := range map[string]func(f *fixture, root string, home *atomic.Bool){
		"locked": func(f *fixture, root string, _ *atomic.Bool) { gitIn(t, f.repo, "worktree", "lock", root) },
		"a merge in progress": func(f *fixture, _ string, _ *atomic.Bool) {
			writeFile(t, filepath.Join(f.repo, ".git", "worktrees", "wt", "MERGE_HEAD"), "0000\n")
		},
		"not the session's":  func(f *fixture, _ string, _ *atomic.Bool) { f.store.ledger = nil },
		"a workbench folder": func(f *fixture, root string, _ *atomic.Bool) { f.store.extraFolders = []string{root} },
		"home unknown":       func(_ *fixture, _ string, home *atomic.Bool) { home.Store(true) },
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root, builds := f.unpushedWithBuild()
			writeFile(t, filepath.Join(root, "notes.txt"), "untracked\n")
			f.endSession()
			var homeGone atomic.Bool
			g := &flipGit{}
			g.flip = func() { flip(f, root, &homeGone) }
			f.git = g
			res := f.apply(Request{PruneBuilds: true}, nil, func(d *Deps) {
				d.Home = func() (string, error) {
					if homeGone.Load() {
						return "", errors.New("no home")
					}
					return f.base, nil
				}
			})
			it := findItem(t, res.Plan, "worktree:"+root)
			if it.Action != ActionKeep || it.Reason != ReasonUncommittedChanges || len(it.BuildsRemoved) > 0 {
				t.Fatalf("item %+v", it)
			}
			for _, b := range builds {
				if !exists(filepath.Join(b, buildMarker)) {
					t.Fatalf("%s went", b)
				}
			}
		})
	}
}

// TestProj18_WorktreeInsideABuildFolderKeepsIt (#2131, review round 2): a
// linked worktree of the repository placed inside a build folder keeps
// that folder, with its uncommitted work; a git clone in
// .build/checkouts (SwiftPM's) does not keep its build folder.
func TestProj18_WorktreeInsideABuildFolderKeepsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, builds := f.unpushedWithBuild()
	hidden := filepath.Join(builds[0], "sub", "lane")
	gitIn(t, f.repo, "worktree", "add", "-q", "-b", "feat/hidden", hidden, "main")
	writeFile(t, filepath.Join(hidden, "work.txt"), "uncommitted\n")
	clone := filepath.Join(builds[1], "checkouts", "pkg")
	gitIn(t, f.base, "clone", "-q", f.repo, clone)
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := findItem(t, res.Plan, "worktree:"+root)
	if !slices.Equal(it.BuildsRemoved, []string{builds[1]}) || it.BuildError != "" {
		t.Fatalf("item %+v", it)
	}
	if !exists(filepath.Join(hidden, "work.txt")) || !exists(filepath.Join(builds[0], buildMarker)) {
		t.Fatal("the worktree inside the build, or its build, went")
	}
	if exists(builds[1]) {
		t.Fatal("the build holding only a clone stayed")
	}
}

// TestProj18_TrackedBuildPathIsMatchedLiterally (review round 2): a build
// folder whose path looks like pathspec magic or a glob still finds its
// tracked file and stays.
func TestProj18_TrackedBuildPathIsMatchedLiterally(t *testing.T) {
	t.Parallel()
	for _, dir := range []string{":(literal)x", "a*"} {
		t.Run(dir, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root, _ := f.unpushedWithBuild()
			tracked := filepath.Join(root, dir, ".build")
			writeFile(t, filepath.Join(tracked, buildMarker), "{}\n")
			gitIn(t, root, "--literal-pathspecs", "add", "-f", filepath.Join(dir, ".build", buildMarker))
			gitIn(t, root, "commit", "-q", "-m", "tracked build")
			f.endSession()

			res := f.apply(Request{PruneBuilds: true}, nil, nil)
			it := findItem(t, res.Plan, "worktree:"+root)
			if slices.Contains(it.BuildsRemoved, tracked) || !exists(filepath.Join(tracked, buildMarker)) {
				t.Fatalf("the tracked build went: %+v", it)
			}
		})
	}
}

// TestProj18_CheckoutOfAnyRepoInABuildKeepsIt (review round 3): a gitfile
// `.git` deep inside a build folder — a linked worktree or submodule
// checkout of any repository, not only this one's — keeps the folder; a
// clone's `.git` directory (SwiftPM's checkouts) does not.
func TestProj18_CheckoutOfAnyRepoInABuildKeepsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, builds := f.unpushedWithBuild()
	writeFile(t, filepath.Join(builds[0], "x", "y", ".git"), "gitdir: /elsewhere/.git/worktrees/y\n")
	writeFile(t, filepath.Join(builds[0], "x", "y", "work.txt"), "uncommitted\n")
	clone := filepath.Join(builds[1], "checkouts", "pkg")
	gitIn(t, f.base, "clone", "-q", f.repo, clone)
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := findItem(t, res.Plan, "worktree:"+root)
	if !slices.Equal(it.BuildsRemoved, []string{builds[1]}) || it.BuildError != "" {
		t.Fatalf("item %+v", it)
	}
	if !exists(filepath.Join(builds[0], "x", "y", "work.txt")) {
		t.Fatal("the checkout inside the build went")
	}
}

// TestHoldsGitfile_FailsClosed: over budget the walk fails (the folder is
// kept by its caller).
func TestHoldsGitfile_FailsClosed(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	for i := range nestedClockEvery + 1 {
		writeFile(t, filepath.Join(dir, "d"+strconv.Itoa(i)), "x")
	}
	if _, err := holdsForeignGit(context.Background(), foundBuild{path: dir, kind: buildKinds[0]}, -time.Second); err == nil {
		t.Fatal("no error over budget")
	}
	if holds, err := holdsForeignGit(context.Background(), foundBuild{path: dir, kind: buildKinds[0]}, time.Minute); holds || err != nil {
		t.Fatalf("holds %v, err %v", holds, err)
	}
}

// TestApply_EvaluatesTheFolderItLocked (review round 3): the folder set is
// read once, before the locks; a session folder that changes in the
// database after that read is not the one evaluated.
func TestApply_EvaluatesTheFolderItLocked(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	other := filepath.Join(f.base, "other")
	gitIn(t, f.base, "init", "-q", "-b", "main", "other")
	f.commit(other, "o.txt", "o\n")
	f.store.session.Folder = f.repo
	f.store.afterSessionRead = func(s *fakeStore) { s.session.Folder = other }
	var locked []string
	res := f.apply(Request{}, nil, func(d *Deps) {
		d.Lock = func(_ context.Context, repo string) (func(), error) {
			locked = append(locked, repo)
			return func() {}, nil
		}
	})
	wantResultItem(t, res, "worktree:"+root, ActionRemove, "", true)
	if !slices.Equal(locked, []string{filepath.Join(f.repo, ".git")}) {
		t.Fatalf("locked %v", locked)
	}
}

// TestProj18_ForeignRepositoryInABuildKeepsIt (review round 4): a git
// repository anywhere in a build folder outside the tool's own clones keeps
// the folder; SwiftPM's checkouts (with their submodules' gitfiles) and
// repositories (bare mirrors) of .build, and Xcode's
// SourcePackages/checkouts of DerivedData, do not.
func TestProj18_ForeignRepositoryInABuildKeepsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root, builds := f.unpushedWithBuild()
	foreign := filepath.Join(builds[0], "some", "other", "repo")
	gitIn(t, f.base, "clone", "-q", f.repo, foreign)
	writeFile(t, filepath.Join(foreign, "edit.txt"), "local edit\n")
	clone := filepath.Join(builds[1], "checkouts", "pkg")
	gitIn(t, f.base, "clone", "-q", f.repo, clone)
	writeFile(t, filepath.Join(clone, "Sub", ".git"), "gitdir: ../.git/modules/Sub\n")
	gitIn(t, f.base, "clone", "-q", "--bare", f.repo, filepath.Join(builds[1], "repositories", "pkg-1234"))
	derived := filepath.Join(root, "build", "DerivedData")
	writeFile(t, filepath.Join(derived, "info.plist"), "<plist/>\n")
	writeFile(t, filepath.Join(derived, "Build", "Products", "App"), "binary\n")
	gitIn(t, f.base, "clone", "-q", f.repo, filepath.Join(derived, "SourcePackages", "checkouts", "pkg"))
	f.endSession()

	res := f.apply(Request{PruneBuilds: true}, nil, nil)
	it := findItem(t, res.Plan, "worktree:"+root)
	got := slices.Clone(it.BuildsRemoved)
	slices.Sort(got)
	want := []string{builds[1], derived}
	slices.Sort(want)
	if !slices.Equal(got, want) || it.BuildError != "" || it.BuildsChecked != true {
		t.Fatalf("item %+v, want removed %v", it, want)
	}
	if !exists(filepath.Join(foreign, "edit.txt")) || !exists(filepath.Join(builds[0], buildMarker)) {
		t.Fatal("the foreign repository in the build, or its build, went")
	}
}

// TestFinishTrash_InterruptedDeleteIsFinishedLater (review round 4): the
// moved build goes first and the marker last, so a delete that fails part
// way leaves a marked leftover the next walk recognises and finishes.
func TestFinishTrash_InterruptedDeleteIsFinishedLater(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	build := swiftBuild(t, filepath.Join(dir, ".build"))
	interrupted := errors.New("interrupted")
	err := removeBuildDir(build, func(p string) error {
		_ = os.Remove(filepath.Join(p, buildMarker)) // part of it went
		return interrupted
	})
	if !errors.Is(err, interrupted) {
		t.Fatalf("err %v", err)
	}
	trash := trashIn(t, dir)
	if len(trash) != 1 || !exists(filepath.Join(trash[0], trashMarker)) {
		t.Fatalf("trash %v, marker missing", trash)
	}
	found, err := findBuildDirs(context.Background(), dir, time.Minute)
	if err != nil || len(found) != 1 || !found[0].trash || found[0].path != trash[0] {
		t.Fatalf("found %+v, err %v", found, err)
	}
	if err := finishTrash(found[0].path, found[0].kind.name, os.RemoveAll); err != nil {
		t.Fatal(err)
	}
	if exists(trash[0]) {
		t.Fatal("the leftover is still there")
	}
}
