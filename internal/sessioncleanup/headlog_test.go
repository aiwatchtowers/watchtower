package sessioncleanup

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// Source §2c of the auto cleanup spec (2026-11-10): the branches created in
// the session's own worktrees, read from git's HEAD logs. Real git; the
// reflog times are set through GIT_COMMITTER_DATE, never waited for.

// gitAt runs git in dir with its reflog and commit times at at.
func gitAt(t *testing.T, dir string, at time.Time, args ...string) {
	t.Helper()
	bin, _ := gitbin.Locate()
	c := exec.Command(bin, args...)
	c.Dir = dir
	stamp := fmt.Sprintf("@%d +0000", at.Unix())
	c.Env = append(os.Environ(), "GIT_COMMITTER_DATE="+stamp, "GIT_AUTHOR_DATE="+stamp)
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// headLogPath is the HEAD log of the linked worktree at root.
func (f *fixture) headLogPath(root string) string {
	return filepath.Join(f.repo, ".git", "worktrees", filepath.Base(root), "logs", "HEAD")
}

// unreadable makes path unreadable until the test ends.
func unreadable(t *testing.T, path string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
}

// sessionWorktree adds a worktree the session worked in (a cwd ledger row),
// created on branch from main with its reflog stamped at.
func (f *fixture) sessionWorktree(name, branch string, at time.Time) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	gitAt(f.t, f.repo, at, "worktree", "add", "-q", "-b", branch, root, "main")
	f.record(root, branch)
	return root
}

func TestProj18_HeadLogBranchOnlyCheckedOutIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t) // the session started an hour ago
	t0 := time.Now().Add(-50 * time.Minute)
	gitAt(t, f.repo, t0.Add(-2*time.Hour), "branch", "other", "main") // older than the session
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0, "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	gitAt(t, wt2, t0.Add(time.Minute), "checkout", "-q", "-b", "late") // younger, made in another worktree
	gitAt(t, wt2, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt2")

	wt := f.sessionWorktree("wt", "feat/wt", t0.Add(5*time.Minute))
	gitAt(t, wt, t0.Add(6*time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(7*time.Minute), "checkout", "-q", "other")
	gitAt(t, wt, t0.Add(8*time.Minute), "checkout", "-q", "late")
	// The state hooks saw the agent on each branch there: the cwd ledger
	// holds every one of them, which alone never makes a branch the
	// session's in a worktree whose HEAD log says it was only checked out.
	for _, br := range []string{"mine", "other", "late"} {
		f.record(wt, br)
	}

	check := func(p Plan) {
		t.Helper()
		wantItem(t, p, "worktree:"+wt, ActionRemove, "")
		wantItem(t, p, "branch:feat/wt", ActionRemove, "")
		wantItem(t, p, "branch:mine", ActionRemove, "")
		wantItem(t, p, "branch:other", ActionKeep, ReasonNotThisSession)
		wantItem(t, p, "branch:late", ActionKeep, ReasonNotThisSession)
		if hasItem(p, "branch:main") {
			t.Fatalf("the default branch is a candidate: %+v", p.Items)
		}
	}
	check(f.plan(Request{}))

	// The same through the database the hooks write: the ledger rows
	// recorded by RecordSessionWorktree, read by DBStore.
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", f.repo)
	if err != nil {
		t.Fatal(err)
	}
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'T', ?, ?, ?)`, wb, f.repo, testUUID, f.sessionCreated.UTC().Format(time.RFC3339))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	for i, br := range []string{"feat/wt", "mine", "other", "late"} {
		at := db.AgentStateStamp(t0.Add(time.Duration(5+i) * time.Minute))
		if _, err := d.RecordSessionWorktree(context.Background(), nil, id, wt, br, at); err != nil {
			t.Fatal(err)
		}
	}
	deps := Deps{Git: SystemGit{}, DB: DBStore{DB: d}, Procs: f.procs, WorktreeBirth: stampBirth,
		ClaudeProjects: func() string { return f.projects }}
	got, err := PlanResult(context.Background(), deps, Request{SessionID: id})
	if err != nil {
		t.Fatal(err)
	}
	check(got.Plan)
}

// A branch created in the session's worktree that another worktree later
// switched to is not the session's.
func TestHeadLogBranchSwitchedToElsewhereIsNotOurs(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	wantItem(t, f.plan(Request{}), "branch:mine", ActionRemove, "")

	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	gitAt(t, wt2, t0.Add(4*time.Minute), "checkout", "-q", "mine")
	gitAt(t, wt2, t0.Add(5*time.Minute), "checkout", "-q", "feat/wt2")
	wantItem(t, f.plan(Request{}), "branch:mine", ActionKeep, ReasonNotThisSession)

	// The main worktree's log counts too.
	f2 := newFixture(t)
	wt = f2.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	gitAt(t, f2.repo, t0.Add(3*time.Minute), "checkout", "-q", "mine")
	gitAt(t, f2.repo, t0.Add(4*time.Minute), "checkout", "-q", "main")
	wantItem(t, f2.plan(Request{}), "branch:mine", ActionKeep, ReasonNotThisSession)
}

// Another worktree's HEAD log cannot be read: the session's created
// branches are kept as created_unknown, and the plan does not fail.
func TestHeadLogOtherLogUnreadableIsCreatedUnknown(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	unreadable(t, f.headLogPath(wt2))

	p := f.plan(Request{})
	wantItem(t, p, "branch:mine", ActionKeep, ReasonCreatedUnknown)
	// The cwd ledger's branch of that worktree goes through §2c too.
	wantItem(t, p, "branch:feat/wt", ActionKeep, ReasonCreatedUnknown)
}

// The session's own worktree's HEAD log exists but cannot be read: the
// plan fails rather than say there is nothing to clean.
func TestHeadLogOwnLogUnreadableFailsPlan(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	wt := f.sessionWorktree("wt", "feat/wt", time.Now().Add(-50*time.Minute))
	unreadable(t, f.headLogPath(wt))
	if res, err := PlanResult(context.Background(), f.deps(), Request{SessionID: testSession}); err == nil {
		t.Fatalf("PlanResult = %+v, want an error", res.Plan.Items)
	}
}

// §2c reads only git: a Codex row gets it as a Claude row does.
func TestHeadLogWorksForCodexRows(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	f.store.session.Kind = "codex"
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "switch", "-q", "-c", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "switch", "-q", "feat/wt")

	p := f.plan(Request{})
	wantItem(t, p, "branch:mine", ActionRemove, "")
	wantNote(t, p, false)
}

// A worktree the session only visited (born before it started) is not
// read: what was created there is not the session's.
func TestHeadLogOfAWorktreeOlderThanTheSessionNamesNothing(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	f.sessionCreated = time.Now().Add(time.Hour)

	if hasItem(f.plan(Request{}), "branch:mine") {
		t.Fatal("a branch of a worktree older than the session is a candidate")
	}
}

// Another worktree that names the branch after its birth — on either side
// of a checkout, or by full ref in another move such as a rebase's
// "returning to refs/heads/<name>" — used it: the branch is not the
// session's. Real git.
func TestHeadLogBranchUsedByAnotherWorktreeRebaseIsNotOurs(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "commit", "-q", "--allow-empty", "-m", "mine")
	gitAt(t, wt, t0.Add(3*time.Minute), "checkout", "-q", "feat/wt")
	gitAt(t, f.repo, t0.Add(4*time.Minute), "commit", "-q", "--allow-empty", "-m", "main moves")
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(5*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
	gitAt(t, wt2, t0.Add(6*time.Minute), "rebase", "-q", "main", "mine")
	gitAt(t, wt2, t0.Add(7*time.Minute), "checkout", "-q", "feat/wt2")

	log, found, err := readHeadLog(f.headLogPath(wt2), "feat/wt2")
	if err != nil || !found {
		t.Fatalf("readHeadLog = %v, %v", found, err)
	}
	var finish, from bool
	for _, e := range log.entries {
		for _, n := range e.names {
			if n != "mine" {
				continue
			}
			if e.at.Equal(time.Unix(t0.Add(6*time.Minute).Unix(), 0)) {
				finish = true // the rebase's own entries
			} else {
				from = true // "checkout: moving from mine to feat/wt2"
			}
		}
	}
	if !finish || !from {
		t.Fatalf("wt2's log names mine in the rebase %v and as a checkout's from side %v: %+v", finish, from, log.entries)
	}
	wantItem(t, f.plan(Request{}), "branch:mine", ActionKeep, ReasonNotThisSession)
	if got := refNames("rebase (finish): returning to refs/heads/mine"); len(got) != 1 || got[0] != "mine" {
		t.Fatalf("refNames = %v", got)
	}
	if got := refNames("merge feat/x: Fast-forward"); len(got) != 0 {
		t.Fatalf("a merge names %v; merging a branch is not using it", got)
	}
}

// A worktree whose HEAD log feeds §2c is one the cwd ledger, placement or
// §2a/§2b gave: a worktree observed only because a target's branch is
// checked out there names nothing through its log.
func TestHeadLogOfATargetBranchWorktreeNamesNothing(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := filepath.Join(f.base, "wt-owner")
	gitAt(t, f.repo, t0, "worktree", "add", "-q", "-b", "feat/target", wt, "main")
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "made")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/target")
	f.store.targetBranches = []string{"feat/target"}

	p := f.plan(Request{})
	wantItem(t, p, "worktree:"+wt, ActionRemove, "")
	wantItem(t, p, "branch:feat/target", ActionRemove, "")
	if hasItem(p, "branch:made") {
		t.Fatalf("a branch of a worktree only a target names was read from its HEAD log: %+v", p.Items)
	}
}

// Another worktree's HEAD log missing, or with a line that does not parse:
// the exclusion cannot be checked, so the created branches stay
// created_unknown (fail closed).
func TestHeadLogOtherLogMissingOrBadIsCreatedUnknown(t *testing.T) {
	t.Parallel()
	for name, spoil := range map[string]func(t *testing.T, path string){
		"missing": func(t *testing.T, path string) {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
		},
		"a bad line": func(t *testing.T, path string) {
			f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			if _, err := f.WriteString("not a reflog line\n"); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			t0 := time.Now().Add(-50 * time.Minute)
			wt := f.sessionWorktree("wt", "feat/wt", t0)
			gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
			gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
			wt2 := filepath.Join(f.base, "wt2")
			gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")
			spoil(t, f.headLogPath(wt2))
			wantItem(t, f.plan(Request{}), "branch:mine", ActionKeep, ReasonCreatedUnknown)
		})
	}
}

// The creation's sha differs from the wt entry that lands in the same
// second: the branch was not made by that step, so it is not named.
func TestHeadLogCreationShaDiffersIsNotNamed(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	t1 := t0.Add(5 * time.Minute)
	gitAt(t, wt, t1, "commit", "-q", "--allow-empty", "-m", "work")
	gitAt(t, f.repo, t1, "branch", "x", "main")
	gitAt(t, wt, t1.Add(time.Minute), "checkout", "-q", "x")
	gitAt(t, wt, t1.Add(2*time.Minute), "checkout", "-q", "feat/wt")

	wantItem(t, f.plan(Request{}), "branch:x", ActionKeep, ReasonNotThisSession)
}

// `git branch x` in the session's worktree, switched to later: not made in
// the step that switched to it, so it is kept (spec §2c "What stays
// unseen").
func TestHeadLogBranchMadeThenSwitchedLaterIsKept(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(5*time.Minute), "branch", "x")
	gitAt(t, wt, t0.Add(6*time.Minute), "checkout", "-q", "x")
	gitAt(t, wt, t0.Add(7*time.Minute), "checkout", "-q", "feat/wt")

	wantItem(t, f.plan(Request{}), "branch:x", ActionKeep, ReasonNotThisSession)
}

// Another worktree whose admin dir is unknown cannot be checked: unknown.
func TestHeadLogOtherAdminDirUnknownIsUnknown(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	wt2 := filepath.Join(f.base, "wt2")
	gitAt(t, f.repo, t0.Add(3*time.Minute), "worktree", "add", "-q", "-b", "feat/wt2", wt2, "main")

	bin, _ := gitbin.Locate()
	r, err := readRepo(context.Background(), gitCmd{run: SystemGit{}, bin: bin}, f.repo, false)
	if err != nil {
		t.Fatal(err)
	}
	delete(r.adminDirs, wt2)
	var own worktree
	for _, w := range r.worktrees {
		if w.Root == wt {
			own = w
		}
	}
	named, _, found, unknown, err := headLogBranches(context.Background(), r, own)
	if err != nil || !found || !unknown || !named["mine"] {
		t.Fatalf("headLogBranches = named %v, found %v, unknown %v, %v; want mine named and unknown", named, found, unknown, err)
	}
}

// A candidate's ref log that exists but cannot be read is no "only
// switched to": it is undecided, created_unknown.
func TestHeadLogRefLogUnreadableIsCreatedUnknown(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	t0 := time.Now().Add(-50 * time.Minute)
	wt := f.sessionWorktree("wt", "feat/wt", t0)
	gitAt(t, wt, t0.Add(time.Minute), "checkout", "-q", "-b", "mine")
	gitAt(t, wt, t0.Add(2*time.Minute), "checkout", "-q", "feat/wt")
	unreadable(t, filepath.Join(f.repo, ".git", "logs", "refs", "heads", "mine"))

	wantItem(t, f.plan(Request{}), "branch:mine", ActionKeep, ReasonCreatedUnknown)
}
