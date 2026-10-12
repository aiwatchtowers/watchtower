package sessioncleanup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPlan_MergedAndPushedWorktreesAreRemoved(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	pushed := f.pushedWork("wt-pushed", "feat/pushed")
	merged := f.worktree("wt-merged", "feat/merged") // no commit of its own: its HEAD is main's
	f.record(pushed, "feat/pushed")
	f.record(merged, "feat/merged")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+pushed, ActionRemove, "")
	wantItem(t, p, "worktree:"+merged, ActionRemove, "")
	wantItem(t, p, "branch:feat/pushed", ActionRemove, "")
	wantItem(t, p, "branch:feat/merged", ActionRemove, "")
	if p.DefaultBranch != "main" {
		t.Fatalf("default branch = %q, want main", p.DefaultBranch)
	}
	if len(p.Items) != 4 {
		t.Fatalf("plan has %d items, want 4: %+v", len(p.Items), p.Items)
	}
}

func TestProj16_UncommittedWorktreeIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	writeFile(t, filepath.Join(root, "README.md"), "edited\n")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonUncommittedChanges)
	// Its branch stays checked out in the kept worktree.
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)
}

func TestProj16_UntrackedFileKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	writeFile(t, filepath.Join(root, "notes.txt"), "new\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonUncommittedChanges)
}

func TestPlan_IgnoredFilesDoNotKeepTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	f.commit(f.repo, ".gitignore", ".build/\n")
	gitIn(t, f.repo, "push", "-q", "origin", "main")
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	writeFile(t, filepath.Join(root, ".build", "debug", "app.o"), "object\n")

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
}

func TestProj16_UnpushedCommitKeepsWorktreeAndBranch(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.worktree("wt", "feat/x")
	f.commit(root, "local.txt", "only here\n")
	f.record(root, "feat/x")

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonUnpushedCommits)
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)

	// A branch alone (no worktree) with an unpushed commit is kept too.
	gitIn(t, f.repo, "branch", "feat/alone", "feat/x")
	f.record(f.repo, "feat/alone")
	wantItem(t, f.plan(Request{}), "branch:feat/alone", ActionKeep, ReasonUnpushedCommits)
}

func TestProj16_LockedWorktreeIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	gitIn(t, f.repo, "worktree", "lock", root)

	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonLocked)
}

func TestPlan_OperationInProgressKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	gitDir := gitIn(t, root, "rev-parse", "--absolute-git-dir")
	head := gitIn(t, root, "rev-parse", "HEAD")
	writeFile(t, filepath.Join(gitDir, "CHERRY_PICK_HEAD"), head+"\n")

	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonOperationInProgress)
	if it.Detail != "CHERRY_PICK_HEAD" {
		t.Fatalf("detail = %q", it.Detail)
	}
}

func TestProj16_WorktreeOlderThanTheSessionIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	f.sessionCreated = time.Now().Add(time.Hour) // the agent only walked into an existing worktree

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonExistedBeforeSession)
	wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)
}

func TestProj16_BranchOlderThanTheSessionIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/old", "main") // merged: only the age keeps it
	f.record(f.repo, "feat/old")
	f.sessionCreated = time.Now().Add(time.Hour)

	wantItem(t, f.plan(Request{}), "branch:feat/old", ActionKeep, ReasonExistedBeforeSession)
}

func TestPlan_BranchWithoutReflogIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "branch", "feat/no-log", "main")
	f.record(f.repo, "feat/no-log")
	if err := os.Remove(filepath.Join(f.repo, ".git", "logs", "refs", "heads", "feat", "no-log")); err != nil {
		t.Fatal(err)
	}

	wantItem(t, f.plan(Request{}), "branch:feat/no-log", ActionKeep, ReasonCreatedUnknown)
}

func TestProj16_BranchCheckedOutElsewhereIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	other := f.pushedWork("wt-other", "feat/x") // not the session's worktree
	f.record(f.repo, "feat/x")                  // the session only saw the branch

	p := f.plan(Request{})
	it := wantItem(t, p, "branch:feat/x", ActionKeep, ReasonCheckedOut)
	if it.Detail != other {
		t.Fatalf("detail = %q, want %s", it.Detail, other)
	}
	if hasItem(p, "worktree:"+other) {
		t.Fatal("a worktree the session never saw is listed")
	}

	// The main folder's own branch counts as checked out too.
	gitIn(t, f.repo, "switch", "-q", "-c", "feat/main-folder")
	f.record(f.repo, "feat/main-folder")
	wantItem(t, f.plan(Request{}), "branch:feat/main-folder", ActionKeep, ReasonCheckedOut)
}

func TestProj16_DefaultBranchIsNeverDeleted(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	gitIn(t, f.repo, "switch", "-q", "--detach")
	f.record(f.repo, "main")

	if p := f.plan(Request{}); hasItem(p, "branch:main") {
		t.Fatalf("the default branch is listed from the ledger: %+v", p.Items)
	}
	wantItem(t, f.plan(Request{DeclaredBranches: []string{"main"}}), "branch:main", ActionKeep, ReasonDefaultBranch)
	if hasItem(f.plan(Request{Sweep: true}), "branch:main") {
		t.Fatal("the sweep lists the default branch")
	}
}

func TestProj16_MainFolderAndWorkbenchFoldersAreNeverCandidates(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	bound := f.pushedWork("wt-bound", "feat/bound") // a second workbench is bound to this worktree
	f.store.extraFolders = []string{filepath.Join(bound, "sub")}
	f.record(f.repo, "main")
	f.record(bound, "feat/bound")

	p := f.plan(Request{})
	if hasItem(p, "worktree:"+f.repo) || hasItem(p, "worktree:"+bound) {
		t.Fatalf("a folder is listed from the ledger: %+v", p.Items)
	}
	wantItem(t, p, "branch:feat/bound", ActionKeep, ReasonCheckedOut)

	p = f.plan(Request{DeclaredWorktrees: []string{f.repo, bound}})
	wantItem(t, p, "worktree:"+f.repo, ActionKeep, ReasonMainFolder)
	wantItem(t, p, "worktree:"+bound, ActionKeep, ReasonWorkbenchFolder)

	p = f.plan(Request{Sweep: true})
	if hasItem(p, "worktree:"+f.repo) || hasItem(p, "worktree:"+bound) {
		t.Fatalf("the sweep lists a folder: %+v", p.Items)
	}
}

func TestProj16_SessionInTheWorktreeKeepsIt(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name       string
		activity   SessionActivity
		live       bool
		caller     int64
		wantReason string
	}{
		{"another live session", SessionActivity{ID: 9, AgentCwd: "sub"}, true, 0, ReasonSessionInIt},
		{"another reported an hour ago", SessionActivity{ID: 9, AgentCwd: "sub", ReportedAt: time.Now().Add(-time.Hour)}, false, 0, ReasonSessionInIt},
		{"another reported 25 h ago, not live", SessionActivity{ID: 9, AgentCwd: "sub", ReportedAt: time.Now().Add(-25 * time.Hour)}, false, 0, ""},
		{"another finished, not live", SessionActivity{ID: 9, AgentCwd: "sub", ReportedAt: time.Now(), Finished: true}, false, 0, ""},
		{"the caller itself", SessionActivity{ID: testSession, AgentCwd: "", ReportedAt: time.Now().Add(-48 * time.Hour)}, false, testSession, ReasonYouAreInIt},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			root := f.pushedWork("wt", "feat/x")
			f.record(root, "feat/x")
			a := tc.activity
			a.AgentCwd = filepath.Join(root, a.AgentCwd)
			f.store.activity = []SessionActivity{a}
			r := Request{CallerSessionID: tc.caller}
			if tc.live {
				r.LiveSessions = []int64{a.ID}
			}
			action := ActionKeep
			if tc.wantReason == "" {
				action = ActionRemove
			}
			wantItem(t, f.plan(r), "worktree:"+root, action, tc.wantReason)
		})
	}
}

func TestProj16_LiveProcessKeepsTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	uid := os.Getuid()
	orphan := Proc{PID: 501, PPID: 1, UID: uid, Start: "Mon Oct 12 10:00:00 2026", Exe: filepath.Join(root, ".build", "stub"), Cwd: root}
	f.procs.list = []Proc{orphan}

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "process:501:Mon Oct 12 10:00:00 2026", ActionRemove, "")

	for _, blocker := range []Proc{
		{PID: 502, PPID: 77, UID: uid, Exe: "/usr/bin/vim", Cwd: root},                                     // has a parent
		{PID: 503, PPID: 1, UID: uid + 1, Exe: "/usr/bin/sleep", Cwd: root},                                // another user
		{PID: 504, PPID: 1, UID: uid, Exe: "/usr/local/bin/claude", Cwd: root},                             // Claude Code
		{PID: 505, PPID: 1, UID: uid, Exe: filepath.Join(root, ".build", "debug", "watchtower"), Cwd: "/"}, // Watchtower's CLI
		{PID: 506, PPID: 1, UID: uid, Exe: "/usr/local/bin/node", Cwd: root},                               // npm-installed codex
		{PID: 507, PPID: 1, UID: uid, Exe: "/opt/homebrew/bin/tmux", Cwd: root},                            // tmux server
	} {
		f.procs.list = []Proc{orphan, blocker}
		it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonProcessRunning)
		if !strings.Contains(it.Detail, filepath.Base(blocker.Exe)) {
			t.Fatalf("detail %q does not name %s", it.Detail, blocker.Exe)
		}
	}

	// A current-user process the scan saw no cwd for keeps every worktree.
	f.procs.list = []Proc{orphan, {PID: 508, PPID: 1, UID: uid, Name: "/usr/bin/vim"}}
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonProcessUnknown)
	if !strings.Contains(it.Detail, "vim pid 508") {
		t.Fatalf("detail %q does not name the unknown process", it.Detail)
	}

	// The sweep never signals, so an orphan keeps the worktree there.
	f.procs.list = []Proc{orphan}
	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionKeep, ReasonProcessRunning)
	if len(f.procs.terminated) != 0 {
		t.Fatalf("a plan signalled %v", f.procs.terminated)
	}
}

func TestPlan_TargetBranchOfALinkedTargetIsACandidate(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/target")
	f.store.targetBranches = []string{"feat/target", "feat/gone-already"}

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+root, ActionRemove, "")
	wantItem(t, p, "branch:feat/target", ActionRemove, "")
	if hasItem(p, "branch:feat/gone-already") {
		t.Fatal("a target branch that does not exist locally is listed")
	}
}

func TestPlan_DeclaredPathThatIsNotAWorktreeIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	plain := filepath.Join(f.base, "plain")
	if err := os.Mkdir(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	p := f.plan(Request{DeclaredWorktrees: []string{plain}, DeclaredBranches: []string{"feat/nope"}})
	wantItem(t, p, "worktree:"+plain, ActionKeep, ReasonNotAWorktree)
	wantItem(t, p, "branch:feat/nope", ActionKeep, ReasonNotABranch)
}

func TestPlan_DeclaredWorktreeStillNeedsToBeYoung(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.sessionCreated = time.Now().Add(time.Hour)
	wantItem(t, f.plan(Request{DeclaredWorktrees: []string{root}}), "worktree:"+root, ActionKeep, ReasonExistedBeforeSession)
}

func TestPlan_PrunableWorktreeIsListed(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	if err := os.RemoveAll(root); err != nil { // the fixture's own temp worktree
		t.Fatal(err)
	}
	it := wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
	if it.Detail != detailGone || !it.BytesKnown || it.Bytes != 0 {
		t.Fatalf("prunable item = %+v", it)
	}
}

func TestPlan_SweepIgnoresOwnershipAndMarksRecentSessions(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	recent := f.pushedWork("wt-recent", "feat/recent")
	stale := f.pushedWork("wt-stale", "feat/stale")
	orphaned := f.pushedWork("wt-unknown", "feat/unknown")
	f.sessionCreated = time.Now().Add(time.Hour) // ownership would keep all three outside the sweep
	f.store.rootOwners = map[string][]int64{recent: {11}, stale: {12}}
	f.store.activity = []SessionActivity{
		{ID: 11, Title: "recent", LastActive: time.Now().Add(-48 * time.Hour)},
		{ID: 12, Title: "stale", LastActive: time.Now().Add(-8 * 24 * time.Hour)},
	}

	p := f.plan(Request{Sweep: true})
	it := wantItem(t, p, "worktree:"+recent, ActionKeep, ReasonSessionRecent)
	if it.Owner == nil || it.Owner.SessionID != 11 {
		t.Fatalf("recent owner = %+v", it.Owner)
	}
	it = wantItem(t, p, "worktree:"+stale, ActionRemove, "")
	if it.Owner == nil || it.Owner.SessionID != 12 || it.Owner.Title != "stale" {
		t.Fatalf("stale owner = %+v", it.Owner)
	}
	it = wantItem(t, p, "worktree:"+orphaned, ActionRemove, "")
	if it.Owner == nil || !it.Owner.Unknown {
		t.Fatalf("unknown owner = %+v", it.Owner)
	}
	if hasItem(p, "branch:feat/recent") || hasItem(p, "branch:main") {
		t.Fatal("the sweep lists a branch checked out in a worktree that stays")
	}
	it = wantItem(t, p, "branch:feat/stale", ActionRemove, "")
	if it.Owner == nil || it.Owner.SessionID != 12 {
		t.Fatalf("stale branch owner = %+v", it.Owner)
	}

	// A live owner keeps it whatever its age.
	wantItem(t, f.plan(Request{Sweep: true, LiveSessions: []int64{12}}), "worktree:"+stale, ActionKeep, ReasonSessionRecent)
}

func TestProj16_PlanWritesNothing(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	pushed := f.pushedWork("wt-pushed", "feat/pushed")
	dirty := f.pushedWork("wt-dirty", "feat/dirty")
	writeFile(t, filepath.Join(dirty, "notes.txt"), "new\n")
	f.record(pushed, "feat/pushed")
	f.record(dirty, "feat/dirty")
	f.procs.list = []Proc{{PID: 501, PPID: 1, UID: os.Getuid(), Start: "x", Exe: filepath.Join(pushed, "stub"), Cwd: pushed}}
	before := repoSnapshot(t, f)

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+pushed, ActionRemove, "")
	_ = f.plan(Request{Sweep: true})

	if after := repoSnapshot(t, f); after != before {
		t.Fatalf("a plan changed the repository:\nbefore:\n%s\nafter:\n%s", before, after)
	}
	if len(f.procs.terminated) != 0 {
		t.Fatalf("a plan signalled %v", f.procs.terminated)
	}
}

// repoSnapshot is the refs, reflogs, worktrees, index and files of the
// fixture, as text.
func repoSnapshot(t *testing.T, f *fixture) string {
	t.Helper()
	var sb strings.Builder
	sb.WriteString(gitIn(t, f.repo, "for-each-ref", "--format=%(refname) %(objectname)"))
	sb.WriteString("\n" + gitIn(t, f.repo, "worktree", "list", "--porcelain"))
	err := filepath.WalkDir(f.base, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		sb.WriteString("\n" + path + " " + info.ModTime().Format(time.RFC3339Nano))
		if !d.IsDir() {
			sb.WriteString(" " + info.Mode().String())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return sb.String()
}

func TestPlan_NoGitIsAnError(t *testing.T) {
	t.Parallel()
	d := Deps{Git: noGit{t: t}, DB: &fakeStore{session: SessionInfo{ID: testSession}}, Procs: &fakeProcs{}}
	_, err := Build(context.Background(), d, Request{SessionID: testSession})
	if !errors.Is(err, ErrNoGit) {
		t.Fatalf("Build without git = %v, want ErrNoGit", err)
	}
}

func TestPlan_SessionOfAnotherWorkbenchIsRefused(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := Build(context.Background(), f.deps(), Request{SessionID: testSession, WorkbenchID: testWorkbench + 1})
	if err == nil || !strings.Contains(err.Error(), "belongs to workbench") {
		t.Fatalf("err = %v", err)
	}
}

func TestPlan_FolderOutsideARepositoryRunsNoGit(t *testing.T) {
	t.Parallel()
	plain := t.TempDir()
	rec := &recordingGit{}
	d := Deps{Git: rec, Procs: &fakeProcs{}, DB: &fakeStore{
		session: SessionInfo{ID: testSession, WorkbenchID: testWorkbench},
		folders: map[int64]string{testWorkbench: plain},
	}}
	if _, err := Build(context.Background(), d, Request{SessionID: testSession}); err == nil {
		t.Fatal("a folder outside any repository planned")
	}
	if rec.calls != 0 {
		t.Fatalf("git ran %d times outside a repository", rec.calls)
	}
}

type recordingGit struct{ calls int }

func (*recordingGit) GitBinary() (string, bool) { return "/nonexistent/git", true }

func (g *recordingGit) RunGit(context.Context, string, string, ...string) ([]byte, int, error) {
	g.calls++
	return nil, -1, errors.New("not run")
}

// Nothing under the owner's ~/.claude is ever removed, in the session's
// cleanup or the sweep; an unknown home directory keeps every worktree.
func TestProj16_ClaudeHomeIsNeverRemoved(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	home := filepath.Join(f.base, "home")
	f.home = func() (string, error) { return home, nil }
	root := filepath.Join(home, ".claude", "worktrees", "agent-1")
	gitIn(t, f.repo, "worktree", "add", "-q", "-b", "feat/agent", root, "main")
	f.commit(root, "agent.txt", "work\n")
	gitIn(t, root, "push", "-q", "origin", "feat/agent")
	f.record(root, "feat/agent")

	p := f.plan(Request{DeclaredWorktrees: []string{root}})
	wantItem(t, p, "worktree:"+root, ActionKeep, ReasonClaudeHome)
	wantItem(t, p, "branch:feat/agent", ActionKeep, ReasonCheckedOut)
	wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionKeep, ReasonClaudeHome)

	if err := os.RemoveAll(root); err != nil { // prunable: still under ~/.claude
		t.Fatal(err)
	}
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonClaudeHome)

	f.home = func() (string, error) { return "", errors.New("no home") }
	wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonCheckFailed)
}
