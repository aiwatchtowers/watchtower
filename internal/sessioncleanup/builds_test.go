package sessioncleanup

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

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
		if exists(b) || exists(filepath.Join(filepath.Dir(b), buildTrashName)) {
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
// a symlinked .build (and its target), a tracked .build and the .build of a
// repository nested in the worktree stay; a leftover of an interrupted
// prune goes.
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
	leftover := filepath.Join(root, "Pkg", buildTrashName)
	writeFile(t, filepath.Join(leftover, "half"), "x\n")
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
		filepath.Join(nestedBuild, buildMarker)} {
		if !exists(p) {
			t.Fatalf("%s went", p)
		}
	}
	if exists(leftover) {
		t.Fatal("the leftover is still there")
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

// TestRemoveBuildDir_CrashLeftoverAndRename: removeBuildDir moves the
// folder aside before deleting it, replacing an older leftover.
func TestRemoveBuildDir_CrashLeftoverAndRename(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	build := swiftBuild(t, filepath.Join(dir, ".build"))
	writeFile(t, filepath.Join(dir, buildTrashName, "old"), "x\n")
	if err := removeBuildDir(build); err != nil {
		t.Fatal(err)
	}
	if exists(build) || exists(filepath.Join(dir, buildTrashName)) {
		t.Fatal("something is left")
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
