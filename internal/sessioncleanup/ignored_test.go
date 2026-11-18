package sessioncleanup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/devpack"
	"watchtower/internal/gitbin"
)

// ignoredFixture is a pushed session worktree in a repository that ignores
// a plan ledger folder, the caches, Watchtower's integration files and an
// .env.
func ignoredFixture(t *testing.T) (*fixture, string) {
	t.Helper()
	f := newFixture(t)
	f.commit(f.repo, ".gitignore",
		".superpowers/\n.build\nnode_modules/\nPods\nbuild/\n.claude/\n.agents/\n.codex/\n.DS_Store\n.env\n.env.local\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	return f, root
}

// installedBin is the binary the fixtures' integration names: another
// watchtower than the one running, as for a worktree set up by an older
// install or from the CLI store.
const installedBin = "/opt/acme old/watchtower"

// writeIntegration writes what the workbench install writes into dir: its
// hooks and cleanup allow rule (devpack's own installers, for installedBin)
// and the two shipped skills with their sidecars, under .claude/skills and
// .agents/skills.
func writeIntegration(t *testing.T, dir string) {
	t.Helper()
	steps := []func() (bool, error){
		func() (bool, error) {
			return devpack.InstallSessionStartHook(dir, devpack.WorkbenchHookCommand(installedBin, testWorkbench), testWorkbench)
		},
		func() (bool, error) {
			return devpack.InstallStopHook(dir, devpack.WorkbenchStopHookCommand(installedBin, testWorkbench), testWorkbench)
		},
		func() (bool, error) { return devpack.InstallStateHooks(dir, installedBin, testWorkbench) },
		func() (bool, error) { return devpack.InstallAskGuardHooks(dir, installedBin, testWorkbench) },
		func() (bool, error) { return devpack.InstallCleanupPermission(dir, installedBin) },
	}
	for _, step := range steps {
		if _, err := step(); err != nil {
			t.Fatal(err)
		}
	}
	for _, skills := range []string{".claude/skills", ".agents/skills"} {
		name, body := devpack.WorkbenchSkill()
		writeSkill(t, filepath.Join(dir, filepath.FromSlash(skills), name), string(body), string(body))
		name, body = devpack.FlowSkill()
		writeSkill(t, filepath.Join(dir, filepath.FromSlash(skills), name), string(body), string(body))
	}
}

// writeSkill writes a skill copy and the sidecar digest of shipped, as the
// install does after writing shipped.
func writeSkill(t *testing.T, dir, content, shipped string) {
	t.Helper()
	sum := sha256.Sum256([]byte(shipped))
	writeFile(t, filepath.Join(dir, "SKILL.md"), content)
	writeFile(t, filepath.Join(dir, ".watchtower-shipped"), hex.EncodeToString(sum[:])+"\n")
}

// TestProj18_IgnoredPlanLedgerKeepsTheWorktree is the #1878 guard (ask
// #1573): a worktree whose only unsaved work is a git-ignored file — an SDD
// ledger under .superpowers/sdd — is kept, in the session's plan, its apply
// and the sweep, while one holding only real caches, a .DS_Store and the
// workbench install's own files (for another watchtower binary) still goes.
func TestProj18_IgnoredPlanLedgerKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
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

// TestProj18_OlderInstallLetsTheWorktreeGo: the install's files are judged
// the way the install judges them, not by today's bytes — a skill copy of
// an older pack version (its sidecar records what we wrote), hooks naming
// another watchtower binary and Claude Code's own "don't ask again" rules
// lose nothing.
func TestProj18_OlderInstallLetsTheWorktreeGo(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	writeIntegration(t, root)
	old := "---\nname: watchtower-workbench\n" + devpack.MarkerKey + ": watchtower\n---\nthe v1 text\n"
	writeSkill(t, filepath.Join(root, ".claude", "skills", devpack.WorkbenchSkillName), old, old)
	settings := filepath.Join(root, ".claude", "settings.local.json")
	b, err := os.ReadFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	withRules := strings.Replace(string(b), `"allow": [`, `"deny": ["Bash(rm:*)"], "allow": ["Bash(make test:*)", `, 1)
	if withRules == string(b) {
		t.Fatalf("no allow list in %s", b)
	}
	writeFile(t, settings, withRules)

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

// The owner's edits keep the worktree: an edited skill copy, an extra file
// in a shipped skill folder, a skill of another name, an extra hook, an
// extra settings key or permission setting, settings that do not parse,
// the .codex files and any other file under .claude.
func TestProj18_OwnersIntegrationEditsKeepTheWorktree(t *testing.T) {
	t.Parallel()
	edited := func(rel, content string) func(t *testing.T, root string) (string, string) {
		return func(t *testing.T, root string) (string, string) {
			writeFile(t, filepath.Join(root, filepath.FromSlash(rel)), content)
			return rel, ""
		}
	}
	settingsWith := func(old, repl string) func(t *testing.T, root string) (string, string) {
		return func(t *testing.T, root string) (string, string) {
			p := filepath.Join(root, ".claude", "settings.local.json")
			b, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			s := strings.Replace(string(b), old, repl, 1)
			if s == string(b) {
				t.Fatalf("%q not in %s", old, b)
			}
			writeFile(t, p, s)
			return ".claude/settings.local.json", ""
		}
	}
	for name, change := range map[string]func(t *testing.T, root string) (string, string){
		"edited skill":              edited(".claude/skills/watchtower-workbench/SKILL.md", "my own version\n"),
		"extra skill file":          edited(".claude/skills/watchtower-flow/notes.md", "notes\n"),
		"legacy skill":              edited(".claude/skills/watchtower-project/SKILL.md", "---\nname: x\n---\nmine\n"),
		"other skill":               edited(".agents/skills/watchtower-mine/SKILL.md", "an owner's skill\n"),
		"extra hook":                settingsWith(`"hooks": {`, `"hooks": {"PreCompact": [{"hooks": [{"type": "command", "command": "./mine.sh"}]}], `),
		"owner command before ours": settingsWith(`"command": "'/opt/acme old/watchtower'`, `"command": "./mine.sh; '/opt/acme old/watchtower'`),
		"changed matcher":           settingsWith(`"matcher": "`, `"matcher": "Bash|`),
		"old prompt hook":           settingsWith(`"type": "command"`, `"type": "prompt", "prompt": "[watchtower-workbench ask-guard 1]"`),
		"extra key":                 settingsWith(`"hooks": {`, `"env": {"A": "1"}, "hooks": {`),
		"permission setting":        settingsWith(`"allow": [`, `"defaultMode": "plan", "allow": [`),
		"unparseable":               edited(".claude/settings.local.json", "{not json\n"),
		"codex hooks":               edited(".codex/hooks.json", "{}\n"),
		"claude notes":              edited(".claude/notes.md", "mine\n"),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f, root := ignoredFixture(t)
			writeIntegration(t, root)
			rel, _ := change(t, root)
			if strings.HasPrefix(rel, ".claude/skills/") {
				rel = filepath.ToSlash(filepath.Dir(rel)) + "/" // the folder's first file is named
			}

			it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
			if !strings.HasPrefix(it.Detail, "ignored file: "+rel) {
				t.Fatalf("detail = %q, want %s", it.Detail, rel)
			}
		})
	}
}

// The integration installed under the workbench's subfolder of the
// repository (cmd's sessionCwdIn) is judged there; `build/` counts as a
// cache at that root too, and deeper it does not.
func TestProj18_SubfolderIntegrationLetsTheWorktreeGo(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	f.commit(f.repo, "app/README.md", "app\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	f.store.folders[testWorkbench] = filepath.Join(f.repo, "app")
	gitIn(t, root, "merge", "-q", "--no-edit", "origin/main")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	sub := filepath.Join(root, "app")
	writeIntegration(t, sub)
	writeFile(t, filepath.Join(sub, "build", "out.bin"), "bin\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	// The subfolder comes from the worktree list, not the include probe:
	// a failed probe leaves the install's files the install's.
	f.git = failGitOn("rev-parse", "--absolute-git-dir")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	f.git = nil

	writeFile(t, filepath.Join(root, "src", "build", "notes.txt"), "mine\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: src/build/notes.txt" {
		t.Fatalf("detail = %q: a nested build folder is not a cache", it.Detail)
	}
}

// Only a real cache folder and a regular .DS_Store lose nothing: a file or
// a symlink named like a cache, or a symlinked .DS_Store, is work.
func TestProj18_CacheNamesCountOnlyAsRealFolders(t *testing.T) {
	t.Parallel()
	for name, mk := range map[string]func(t *testing.T, root string) string{
		"file named Pods": func(t *testing.T, root string) string {
			writeFile(t, filepath.Join(root, "ios", "Pods"), "my notes\n")
			return "ios/Pods"
		},
		"symlinked .build": func(t *testing.T, root string) string {
			if err := os.Symlink(t.TempDir(), filepath.Join(root, ".build")); err != nil {
				t.Fatal(err)
			}
			return ".build"
		},
		"symlinked .DS_Store": func(t *testing.T, root string) string {
			if err := os.Symlink(filepath.Join(root, "wt.txt"), filepath.Join(root, ".DS_Store")); err != nil {
				t.Fatal(err)
			}
			return ".DS_Store"
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f, root := ignoredFixture(t)
			rel := mk(t, root)
			it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
			if it.Detail != "ignored file: "+rel {
				t.Fatalf("detail = %q, want %s", it.Detail, rel)
			}
		})
	}
}

// A file .worktreeinclude copies goes while it is byte-identical to its
// source in the main worktree; a changed copy, or an ignored file the list
// does not name (even one equal to main's), keeps the worktree.
func TestProj18_WorktreeIncludeCopyGoesOnlyUnchanged(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	f.commit(f.repo, ".worktreeinclude", ".env\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	gitIn(t, root, "merge", "-q", "--no-edit", "origin/main")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	writeFile(t, filepath.Join(f.repo, ".env"), "TOKEN=placeholder\n")
	writeFile(t, filepath.Join(root, ".env"), "TOKEN=placeholder\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")

	writeFile(t, filepath.Join(root, ".env"), "TOKEN=changed\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .env" {
		t.Fatalf("detail = %q", it.Detail)
	}

	writeFile(t, filepath.Join(root, ".env"), "TOKEN=placeholder\n")
	writeFile(t, filepath.Join(f.repo, ".env.local"), "same\n")
	writeFile(t, filepath.Join(root, ".env.local"), "same\n")
	it = wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .env.local" {
		t.Fatalf("detail = %q: a file the list does not name is work", it.Detail)
	}
}

// The copies come from the checkout the workbench is registered in, which
// may be a linked one: a session's .env equal to the main checkout's but not
// to that source's is work; equal to the source's, it goes.
func TestProj18_WorktreeIncludeComparesWithTheSourceCheckout(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	linked := f.worktree("linked", "feat/linked")
	f.store.folders[testWorkbench] = linked
	writeFile(t, filepath.Join(linked, ".worktreeinclude"), ".env\n")
	writeFile(t, filepath.Join(linked, ".env"), "TOKEN=linked\n")
	writeFile(t, filepath.Join(f.repo, ".worktreeinclude"), ".env\n")
	writeFile(t, filepath.Join(f.repo, ".env"), "TOKEN=main\n")

	writeFile(t, filepath.Join(root, ".env"), "TOKEN=main\n")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .env" {
		t.Fatalf("detail = %q: equal to main's, not to the source's", it.Detail)
	}

	writeFile(t, filepath.Join(root, ".env"), "TOKEN=linked\n")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

// The include source is located through the cleanup's own git runner: a
// probe that fails lets no ignored file pass as a copy (the worktree stays,
// ignored_files), and subfolder integration files are still the install's.
func TestProj18_FailedIncludeProbeLetsNoCopyPass(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	f.commit(f.repo, ".worktreeinclude", ".env\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	gitIn(t, root, "merge", "-q", "--no-edit", "origin/main")
	gitIn(t, root, "push", "-q", "origin", "feat/x")
	writeFile(t, filepath.Join(f.repo, ".env"), "TOKEN=placeholder\n")
	writeFile(t, filepath.Join(root, ".env"), "TOKEN=placeholder\n")
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")

	f.git = failGitOn("rev-parse", "--absolute-git-dir")
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonIgnoredFiles)
	if it.Detail != "ignored file: .env" {
		t.Fatalf("detail = %q", it.Detail)
	}
}

// stallGit answers every git call only when its context ends.
type stallGit struct{ SystemGit }

func (stallGit) RunGit(ctx context.Context, _, _ string, args ...string) ([]byte, int, error) {
	<-ctx.Done()
	return nil, -1, fmt.Errorf("git %s: %w", strings.Join(args, " "), ctx.Err())
}

// A probe that stalls past the judge's budget is a failed judgement
// (check_failed), not "no source"; the expired deadline means no wait.
func TestIgnoredJudge_StalledIncludeProbeIsOverTheBudget(t *testing.T) {
	t.Parallel()
	root, source := t.TempDir(), t.TempDir()
	gitIn(t, source, "init", "-q") // a repository, so the probe reaches git and stalls there
	writeFile(t, filepath.Join(root, ".env"), "A\n")
	info, err := os.Lstat(filepath.Join(root, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	bin, _ := gitbin.Locate()
	j := overBudget(context.Background(), root)
	j.git, j.folder = gitCmd{run: stallGit{}, bin: bin}, source
	if _, err := j.includedCopy(".env", info); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("err = %v, want the budget", err)
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

// The failure path: git failing on the ignored listing, or on the
// .worktreeinclude listing, keeps the worktree as check_failed, never
// removes it — in the plan and in the apply's re-check.
func TestProj18_IgnoredListingFailureKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
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

	writeFile(t, filepath.Join(f.repo, ".worktreeinclude"), ".env\n")
	writeFile(t, filepath.Join(f.repo, ".env"), "A\n")
	writeFile(t, filepath.Join(root, ".env"), "A\n")
	f.git = failGitOn("ls-files", "-z", "--others", "--ignored")
	it = wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
	if !strings.Contains(it.Detail, "injected failure") {
		t.Fatalf("detail = %q, want the include listing's error", it.Detail)
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

// An ignored file written after the plan, right before the removal, is
// caught by the pre-remove re-check: the worktree stays and git worktree
// remove never runs.
func TestApply_IgnoredFileRightBeforeTheRemoveKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
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

// overBudget is a judge whose budget already ran out, so every check fails
// without waiting on the clock.
func overBudget(ctx context.Context, root string) *ignoredJudge {
	return &ignoredJudge{ctx: ctx, root: root, bases: []string{""}, skills: map[string]bool{},
		deadline: time.Now().Add(-time.Second), budget: time.Nanosecond}
}

// The judgement shares W9's budget and context: a walk, a comparison of
// file bytes and the listing loop all stop over it (the catch then keeps
// the worktree as check_failed).
func TestIgnoredJudge_OverTheBudgetFails(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for i := range nestedClockEvery {
		writeFile(t, filepath.Join(root, "ign", fmt.Sprintf("d%d", i), ".DS_Store"), "x")
	}
	if _, err := overBudget(context.Background(), root).entry("ign/"); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("walk err = %v, want the budget", err)
	}

	a, b := filepath.Join(root, "a"), filepath.Join(root, "b")
	writeFile(t, a, "same\n")
	writeFile(t, b, "same\n")
	if _, err := overBudget(context.Background(), root).sameBytes(a, b); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("compare err = %v, want the budget", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	j := overBudget(ctx, root)
	j.deadline, j.budget = time.Now().Add(time.Hour), time.Hour
	if _, err := j.entry("ign/"); err == nil {
		t.Fatal("a cancelled walk passed")
	}
}

// The listing loop checks the budget before each entry.
func TestProj18_IgnoredListingOverTheBudgetKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f, root := ignoredFixture(t)
	writeFile(t, filepath.Join(root, ".DS_Store"), "x")
	bin, _ := gitbin.Locate()
	b := &builder{repo: &repoState{git: gitCmd{run: SystemGit{}, bin: bin}, folder: f.repo}}
	if _, err := b.ignoredWork(context.Background(), root, -time.Second); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("err = %v, want the budget", err)
	}
}

func TestIgnoredJudge_CacheName(t *testing.T) {
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
		if got := j.cacheName(rel); got != want {
			t.Errorf("cacheName(%q) = %v, want %v", rel, got, want)
		}
	}
}
