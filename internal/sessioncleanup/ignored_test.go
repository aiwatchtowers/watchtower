package sessioncleanup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ignoredFixture is a pushed session worktree in a repository that ignores
// a plan ledger folder, the caches and Watchtower's integration files.
func ignoredFixture(t *testing.T) (*fixture, string) {
	t.Helper()
	f := newFixture(t)
	f.commit(f.repo, ".gitignore", ".superpowers/\n.build/\nnode_modules/\n.claude/\n.DS_Store\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	return f, root
}

// TestProj18_IgnoredPlanLedgerKeepsTheWorktree is the #1878 guard (ask
// #1573): a worktree whose only unsaved work is a git-ignored file — an SDD
// ledger under .superpowers/sdd — is kept, in the session's plan, its apply
// and the sweep, while one holding only caches and Watchtower's own
// integration files still goes.
func TestProj18_IgnoredPlanLedgerKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	writeFile(t, filepath.Join(root, ".build", "debug", "app.o"), "object\n")
	writeFile(t, filepath.Join(root, "WatchtowerDesktop", ".build", "x.o"), "object\n")
	writeFile(t, filepath.Join(root, "node_modules", "pkg", "index.js"), "js\n")
	writeFile(t, filepath.Join(root, ".claude", "settings.local.json"), "{}\n")
	writeFile(t, filepath.Join(root, ".claude", "skills", "watchtower-workbench", "SKILL.md"), "skill\n")
	writeFile(t, filepath.Join(root, ".DS_Store"), "x")

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

// A user's own file under an ignored .claude/ (not Watchtower's) is work.
func TestPlan_IgnoredFileOutsideTheIntegrationKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	writeFile(t, filepath.Join(root, ".claude", "notes.md"), "mine\n")

	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .claude/notes.md" {
		t.Fatalf("detail = %q", it.Detail)
	}
}

// A symlink in an ignored folder is judged as an entry and never followed:
// the link itself keeps the worktree, and its target is not read.
func TestPlan_IgnoredSymlinkIsNotFollowed(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
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

// The failure path: git failing on the ignored listing keeps the worktree
// as check_failed, never removes it — in the plan and in the apply's
// re-check.
func TestProj18_IgnoredListingFailureKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
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
}

// An unreadable ignored folder keeps the worktree (check_failed).
func TestPlan_UnreadableIgnoredFolderKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	if os.Geteuid() == 0 {
		t.Skip("root reads every folder")
	}
	f, root := ignoredFixture(t)
	dir := filepath.Join(root, ".superpowers", "sdd")
	writeFile(t, filepath.Join(dir, "x.md"), "x\n")
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
}

func TestRegenerable(t *testing.T) {
	t.Parallel()
	for rel, want := range map[string]bool{
		".build/":                                  true,
		"WatchtowerDesktop/.build/debug/a.o":       true,
		"ios/DerivedData/":                         true,
		"build/":                                   true,
		"web/node_modules/x/":                      true,
		"Pkg/.swiftpm/":                            true,
		".DS_Store":                                true,
		"a/.DS_Store":                              true,
		".claude/settings.local.json":              true,
		".claude/skills/watchtower-flow/":          true,
		".agents/skills/watchtower-workbench/a.md": true,
		".codex/hooks.json":                        true,
		".superpowers/":                            false,
		".claude/":                                 false,
		".claude/skills/my-skill/":                 false,
		"buildnotes.md":                            false,
		"rebuild/x":                                false,
		".env":                                     false,
	} {
		if got := regenerable(rel); got != want {
			t.Errorf("regenerable(%q) = %v, want %v", rel, got, want)
		}
	}
}
