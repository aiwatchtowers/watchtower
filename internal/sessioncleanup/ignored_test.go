package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeIntegration renders a fixed set of Watchtower's install files and
// records the folders it was asked about.
type fakeIntegration struct {
	mu      sync.Mutex
	folders []string
	err     error
}

var renderedFiles = map[string]string{
	".claude/settings.local.json":                  "{\"hooks\":{}}\n",
	".claude/skills/watchtower-workbench/SKILL.md": "the workbench skill\n",
	".agents/skills/watchtower-workbench/SKILL.md": "the workbench skill\n",
}

func (r *fakeIntegration) render(_ context.Context, id int64, folder string) (map[string][]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.folders = append(r.folders, folder)
	if id != testWorkbench {
		return nil, fmt.Errorf("rendered for workbench %d", id)
	}
	if r.err != nil {
		return nil, r.err
	}
	files := map[string][]byte{}
	for k, v := range renderedFiles {
		files[k] = []byte(v)
	}
	return files, nil
}

// ignoredFixture is a pushed session worktree in a repository that ignores
// a plan ledger folder, the caches, Watchtower's integration files and an
// .env; integration renders Watchtower's files.
func ignoredFixture(t *testing.T) (*fixture, string, *fakeIntegration) {
	t.Helper()
	f := newFixture(t)
	f.commit(f.repo, ".gitignore",
		".superpowers/\n.build/\nnode_modules/\nPods/\nbuild/\n.claude/\n.agents/\n.codex/\n.DS_Store\n.env\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	r := &fakeIntegration{}
	f.integration = r.render
	return f, root, r
}

// writeIntegration writes the rendered files under dir.
func writeIntegration(t *testing.T, dir string) {
	t.Helper()
	for rel, content := range renderedFiles {
		writeFile(t, filepath.Join(dir, filepath.FromSlash(rel)), content)
	}
}

// TestProj18_IgnoredPlanLedgerKeepsTheWorktree is the #1878 guard (ask
// #1573): a worktree whose only unsaved work is a git-ignored file — an SDD
// ledger under .superpowers/sdd — is kept, in the session's plan, its apply
// and the sweep, while one holding only caches, a .DS_Store and
// Watchtower's integration files exactly as the install writes them still
// goes.
func TestProj18_IgnoredPlanLedgerKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root, _ := ignoredFixture(t)
	writeFile(t, filepath.Join(root, ".build", "debug", "app.o"), "object\n")
	writeFile(t, filepath.Join(root, "WatchtowerDesktop", ".build", "x.o"), "object\n")
	writeFile(t, filepath.Join(root, "node_modules", "pkg", "index.js"), "js\n")
	writeFile(t, filepath.Join(root, "ios", "Pods", "Lib", "a.m"), "m\n")
	writeFile(t, filepath.Join(root, "build", "out.bin"), "bin\n")
	writeFile(t, filepath.Join(root, ".DS_Store"), "x")
	writeIntegration(t, root)

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionRemove, "")

	ledger := filepath.Join(root, ".superpowers", "sdd", "plan", "progress.md")
	writeFile(t, ledger, "Task 1: done\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .superpowers/sdd/plan/progress.md" {
		t.Fatalf("detail = %q, want the ledger's path", it.Detail)
	}
	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)

	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonIgnoredFiles, false)
	if _, err := os.Stat(ledger); err != nil {
		t.Fatalf("the ledger is gone: %v", err)
	}
}

// Nothing that can hold the owner's words goes by its name alone: an edited
// settings.local.json, a skill folder the install does not write, an extra
// file in a shipped skill folder, the codex files, and a file under an
// ignored .claude/ that is not Watchtower's each keep the worktree.
func TestPlan_IntegrationLooksOnlyPassWhenTheirBytesMatch(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct{ rel, content string }{
		{".claude/settings.local.json", "{\"permissions\":{\"allow\":[\"Bash(make:*)\"]}}\n"},
		{".claude/skills/watchtower-flow/SKILL.md", "the flow skill\n"},
		{".claude/skills/watchtower-project/SKILL.md", "the legacy skill\n"},
		{".claude/skills/watchtower-mine/SKILL.md", "an owner's skill\n"},
		{".claude/skills/watchtower-workbench/notes.md", "notes\n"},
		{".codex/hooks.json", "{}\n"},
		{".codex/config.toml", "x = 1\n"},
		{".claude/notes.md", "mine\n"},
	} {
		t.Run(tc.rel, func(t *testing.T) {
			t.Parallel()
			f, root, _ := ignoredFixture(t)
			writeIntegration(t, root)
			writeFile(t, filepath.Join(root, filepath.FromSlash(tc.rel)), tc.content)

			it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
			if it.Detail != "ignored file: "+tc.rel {
				t.Fatalf("detail = %q", it.Detail)
			}
		})
	}
}

// With no renderer (Deps.Integration nil) no file is Watchtower's.
func TestPlan_NoRendererKeepsIntegrationFiles(t *testing.T) {
	t.Parallel()
	f, root, _ := ignoredFixture(t)
	f.integration = nil
	writeIntegration(t, root)

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
}

// The integration installed under the workbench's subfolder of the
// repository (cmd's sessionCwdIn) is matched there, rendered for that
// folder; `build/` counts as a cache at that root too, and deeper it does
// not.
func TestProj18_SubfolderIntegrationLetsTheWorktreeGo(t *testing.T) {
	t.Parallel()
	f, root, r := ignoredFixture(t)
	f.commit(f.repo, "app/README.md", "app\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	f.store.folders[testWorkbench] = filepath.Join(f.repo, "app")
	gitIn(t, root, "merge", "-q", "--no-edit", "origin/main")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	sub := filepath.Join(root, "app")
	writeIntegration(t, sub)
	writeFile(t, filepath.Join(sub, "build", "out.bin"), "bin\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	if !slices.Contains(r.folders, sub) {
		t.Fatalf("rendered for %v, want the subfolder %s", r.folders, sub)
	}

	writeFile(t, filepath.Join(root, "src", "build", "notes.txt"), "mine\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: src/build/notes.txt" {
		t.Fatalf("detail = %q: a nested build folder is not a cache", it.Detail)
	}
}

// A file .worktreeinclude copied in goes while it is byte-identical to its
// source in the main worktree; a changed copy keeps the worktree.
func TestProj18_WorktreeIncludeCopyGoesOnlyUnchanged(t *testing.T) {
	t.Parallel()
	f, root, _ := ignoredFixture(t)
	writeFile(t, filepath.Join(f.repo, ".env"), "TOKEN=placeholder\n")
	writeFile(t, filepath.Join(root, ".env"), "TOKEN=placeholder\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")

	writeFile(t, filepath.Join(root, ".env"), "TOKEN=changed\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .env" {
		t.Fatalf("detail = %q", it.Detail)
	}
}

// A symlink in an ignored folder is judged as an entry and never followed:
// the link itself keeps the worktree, and its target is not read.
func TestPlan_IgnoredSymlinkIsNotFollowed(t *testing.T) {
	t.Parallel()
	f, root, _ := ignoredFixture(t)
	if err := os.MkdirAll(filepath.Join(root, ".superpowers"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(root, ".superpowers", "link")); err != nil {
		t.Fatal(err)
	}

	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .superpowers/link" {
		t.Fatalf("detail = %q", it.Detail)
	}
}

// The failure path: git failing on the ignored listing, or the renderer
// failing, keeps the worktree as check_failed, never removes it — in the
// plan and in the apply's re-check.
func TestProj18_IgnoredListingFailureKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root, r := ignoredFixture(t)
	writeIntegration(t, root)
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")

	f.git = failGitOn("status", "--porcelain", "-z", "--ignored=matching")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
	if !strings.Contains(it.Detail, "injected failure") {
		t.Fatalf("detail = %q, want the git error", it.Detail)
	}
	res := f.apply(Request{}, nil, nil)
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonCheckFailed, false)
	if !exists(root) {
		t.Fatal("the worktree was removed after a failed check")
	}

	f.git = nil
	r.err = errors.New("no binary path")
	it = wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
	if !strings.Contains(it.Detail, "no binary path") {
		t.Fatalf("detail = %q, want the render error", it.Detail)
	}
}

// An unreadable ignored folder keeps the worktree (check_failed).
func TestPlan_UnreadableIgnoredFolderKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	if os.Geteuid() == 0 {
		t.Skip("root reads every folder")
	}
	f, root, _ := ignoredFixture(t)
	dir := filepath.Join(root, ".superpowers", "sdd")
	writeFile(t, filepath.Join(dir, "x.md"), "x\n")
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
}

// An ignored file written after the plan, right before the removal, is
// caught by the pre-remove re-check: the worktree stays and git worktree
// remove never runs.
func TestApply_IgnoredFileRightBeforeTheRemoveKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root, _ := ignoredFixture(t)
	log := &opLog{}
	ls := &fakeLS{log: log, onUnregister: func(string) {
		writeFile(t, filepath.Join(root, ".superpowers", "sdd", "progress.md"), "late\n")
	}}
	f.git = &loggingGit{log: log}

	res := f.apply(Request{}, nil, func(d *Deps) { d.LS = ls })
	wantResultItem(t, res, "worktree:"+root, ActionKeep, ReasonIgnoredFiles, false)
	if slices.Contains(log.list(), "git worktree remove "+root) {
		t.Fatal("git worktree remove ran after the re-check found the ignored file")
	}
}

// The walk shares W9's budget and clock: over it the judgement fails (the
// catch keeps the worktree as check_failed), without waiting on the clock.
func TestIgnoredJudge_OverTheBudgetFails(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for i := range nestedClockEvery {
		writeFile(t, filepath.Join(root, "ign", fmt.Sprintf("d%d", i), ".DS_Store"), "x")
	}
	j := &ignoredJudge{ctx: context.Background(), root: root, bases: []string{""},
		rendered: map[string]map[string][]byte{}, deadline: time.Now().Add(-time.Second), budget: time.Nanosecond}
	if _, err := j.entry("ign/"); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("err = %v, want the budget", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	j = &ignoredJudge{ctx: ctx, root: root, bases: []string{""},
		rendered: map[string]map[string][]byte{}, deadline: time.Now().Add(time.Hour), budget: time.Hour}
	if _, err := j.entry("ign/"); err == nil {
		t.Fatal("a cancelled walk passed")
	}
}

func TestIgnoredJudge_CacheDir(t *testing.T) {
	t.Parallel()
	j := &ignoredJudge{bases: []string{"", "app"}}
	for rel, want := range map[string]bool{
		".build":                       true,
		"WatchtowerDesktop/.build/a.o": true,
		"ios/DerivedData":              true,
		"web/node_modules/x":           true,
		"ios/Pods/Lib":                 true,
		"Pkg/.swiftpm":                 true,
		"build":                        true,
		"build/out.bin":                true,
		"app/build/out.bin":            true,
		"src/build/out.bin":            false,
		"app/src/build/x":              false,
		"buildnotes.md":                false,
		".superpowers/sdd":             false,
	} {
		if got := j.cacheDir(rel); got != want {
			t.Errorf("cacheDir(%q) = %v, want %v", rel, got, want)
		}
	}
}
