package sessioncleanup

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// fixture is a repository on main pushed to a bare "remote" (origin, with
// origin/HEAD set), inside a symlink-resolved temp dir. Worktrees go next
// to it.
type fixture struct {
	t              *testing.T
	base, repo     string
	store          *fakeStore
	procs          *fakeProcs
	sessionCreated time.Time
	git            GitRunner // nil = SystemGit
	home           func() (string, error)
	// birth reads a worktree's birth; nil = stampBirth, so the catches
	// after ownership run on every platform (the real birth is darwin-only).
	birth func(adminDir string) (time.Time, bool)
	// projects is the Claude Code projects directory the plan reads: an
	// empty one under base, never the developer's.
	projects string
	// clock is Deps.Clock; nil = the wall clock.
	clock func() time.Time
}

// stampBirth stands in for the filesystem birth time: a fixture's admin dir
// is fresh, so its mtime is when `git worktree add` made it.
func stampBirth(adminDir string) (time.Time, bool) {
	fi, err := os.Stat(adminDir)
	if err != nil {
		return time.Time{}, false
	}
	return fi.ModTime(), true
}

const testSession, testWorkbench = int64(7), int64(3)

func newFixture(t *testing.T) *fixture {
	t.Helper()
	if _, ok := gitbin.Locate(); !ok {
		t.Skip("git is not available")
	}
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, base: base, repo: filepath.Join(base, "repo"), procs: &fakeProcs{},
		projects: filepath.Join(base, "claude-projects")}
	if err := os.MkdirAll(f.projects, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, base, "init", "-q", "--bare", "-b", "main", "remote.git")
	gitIn(t, base, "init", "-q", "-b", "main", "repo")
	f.commit(f.repo, "README.md", "hello\n")
	gitIn(t, f.repo, "remote", "add", "origin", filepath.Join(base, "remote.git"))
	gitIn(t, f.repo, "push", "-q", "-u", "origin", "main")
	gitIn(t, f.repo, "remote", "set-head", "origin", "main")
	// The session started before anything the test creates from here on.
	f.sessionCreated = time.Now().Add(-time.Hour)
	f.store = &fakeStore{
		folders: map[int64]string{testWorkbench: f.repo},
		session: SessionInfo{ID: testSession, WorkbenchID: testWorkbench},
	}
	return f
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	bin, _ := gitbin.Locate()
	c := exec.Command(bin, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) commit(dir, name, content string) {
	f.t.Helper()
	writeFile(f.t, filepath.Join(dir, name), content)
	gitIn(f.t, dir, "add", name)
	gitIn(f.t, dir, "commit", "-q", "-m", "change "+name)
}

// worktree adds a linked worktree on a new branch from main and returns
// its root.
func (f *fixture) worktree(name, branch string) string {
	f.t.Helper()
	root := filepath.Join(f.base, name)
	gitIn(f.t, f.repo, "worktree", "add", "-q", "-b", branch, root, "main")
	return root
}

// pushedWork adds a worktree whose branch carries one commit pushed to
// origin: nothing in it is at risk.
func (f *fixture) pushedWork(name, branch string) string {
	f.t.Helper()
	root := f.worktree(name, branch)
	f.commit(root, name+".txt", "work\n")
	gitIn(f.t, root, "push", "-q", "origin", branch)
	return root
}

// record adds a ledger row of the test session.
func (f *fixture) record(root, branch string) {
	f.store.ledger = append(f.store.ledger, db.SessionWorktree{Root: root, Branch: branch, FirstAt: "2026-10-12T12:00:00.000Z"})
}

func (f *fixture) deps() Deps {
	f.store.session.CreatedAt = f.sessionCreated
	var g GitRunner = SystemGit{}
	if f.git != nil {
		g = f.git
	}
	birth := f.birth
	if birth == nil {
		birth = stampBirth
	}
	projects := f.projects
	return Deps{Git: g, DB: f.store, Procs: f.procs, Home: f.home, WorktreeBirth: birth,
		ClaudeProjects: func() string { return projects }, Clock: f.clock}
}

func (f *fixture) plan(r Request) Plan {
	f.t.Helper()
	if r.SessionID == 0 && !r.Sweep {
		r.SessionID = testSession
	}
	if r.Sweep {
		r.WorkbenchID = testWorkbench
	}
	res, err := PlanResult(context.Background(), f.deps(), r)
	if err != nil {
		f.t.Fatalf("PlanResult: %v", err)
	}
	return res.Plan
}

func findItem(t *testing.T, p Plan, key string) Item {
	t.Helper()
	for _, it := range p.Items {
		if it.Key == key {
			return it
		}
	}
	t.Fatalf("no item %s in %+v", key, p.Items)
	return Item{}
}

func hasItem(p Plan, key string) bool {
	for _, it := range p.Items {
		if it.Key == key {
			return true
		}
	}
	return false
}

func wantItem(t *testing.T, p Plan, key, action, reason string) Item {
	t.Helper()
	it := findItem(t, p, key)
	if it.Action != action || it.Reason != reason {
		t.Fatalf("%s = %s/%q (detail %q), want %s/%q", key, it.Action, it.Reason, it.Detail, action, reason)
	}
	return it
}

// fakeStore serves one workbench and one session; it has no write method
// because Store has none.
type fakeStore struct {
	session        SessionInfo
	ledger         []db.SessionWorktree
	targetBranches []string
	folders        map[int64]string
	extraFolders   []string
	// bench is the workbench's live folders (BenchFolders), home first;
	// nil = its home folder alone.
	bench []string
	// benchErr fails BenchFolders.
	benchErr   error
	activity   []SessionActivity
	rootOwners map[string][]int64
	// ledgerOwners are the owners of every workbench's ledger
	// (SessionWorktreeOwners); nil = rootOwners.
	ledgerOwners map[string][]int64
	// lastSeen is the newest ledger sighting per root; seenErr fails the read.
	lastSeen map[string]time.Time
	seenErr  error
	// onLastSeen, when set, runs on every WorktreeLastSeen read (an idle
	// walk reads it first).
	onLastSeen func(root string)
	// agentIDs are the session's agent session ids; uuidOwners the rows
	// holding each uuid (absent = none, which adopts nothing); idsErr and
	// ownersErr fail those reads.
	agentIDs          []db.AgentSessionID
	uuidOwners        map[string][]int64
	idsErr, ownersErr error
	// afterSessionRead, when set, runs once after the first CleanupSession
	// read: the database changing between two reads.
	afterSessionRead func(*fakeStore)
}

func (s *fakeStore) CleanupSession(_ context.Context, id int64) (SessionInfo, error) {
	if id != s.session.ID {
		return SessionInfo{}, db.ErrTerminalSessionNotFound
	}
	out := s.session
	if s.afterSessionRead != nil {
		s.afterSessionRead(s)
		s.afterSessionRead = nil
	}
	return out, nil
}

func (s *fakeStore) SessionWorktrees(context.Context, int64) ([]db.SessionWorktree, error) {
	return s.ledger, nil
}

func (s *fakeStore) SessionTargetBranches(context.Context, int64) ([]string, error) {
	return s.targetBranches, nil
}

func (s *fakeStore) AgentSessionIDs(context.Context, int64) ([]db.AgentSessionID, error) {
	return s.agentIDs, s.idsErr
}

func (s *fakeStore) AgentSessionIDOwners(_ context.Context, uuids []string) (map[string][]int64, error) {
	if s.ownersErr != nil {
		return nil, s.ownersErr
	}
	out := map[string][]int64{}
	for _, u := range uuids {
		if o, ok := s.uuidOwners[u]; ok {
			out[u] = o
		}
	}
	return out, nil
}

func (s *fakeStore) WorkbenchFolder(_ context.Context, id int64) (string, error) {
	return s.folders[id], nil
}

func (s *fakeStore) WorkbenchFolders(context.Context) ([]string, error) {
	out := append(append([]string(nil), s.extraFolders...), s.bench...)
	for _, f := range s.folders {
		out = append(out, f)
	}
	return out, nil
}

func (s *fakeStore) BenchFolders(_ context.Context, id int64) ([]string, error) {
	if s.benchErr != nil {
		return nil, s.benchErr
	}
	if s.bench == nil {
		return []string{s.folders[id]}, nil
	}
	return s.bench, nil
}

func (s *fakeStore) WorkbenchSessionWorktrees(context.Context, int64) (map[string][]int64, error) {
	if s.rootOwners == nil {
		return map[string][]int64{}, nil
	}
	return s.rootOwners, nil
}

func (s *fakeStore) SessionWorktreeOwners(ctx context.Context) (map[string][]int64, error) {
	if s.ledgerOwners == nil {
		return s.WorkbenchSessionWorktrees(ctx, 0)
	}
	return s.ledgerOwners, nil
}

func (s *fakeStore) AllSessionActivity(context.Context) ([]SessionActivity, error) {
	return s.activity, nil
}

func (s *fakeStore) SessionActivityOf(_ context.Context, id int64) (SessionActivity, bool, error) {
	for _, a := range s.activity {
		if a.ID == id {
			return a, true, nil
		}
	}
	return SessionActivity{}, false, nil
}

func (s *fakeStore) WorktreeLastSeen(_ context.Context, root string) (time.Time, bool, error) {
	if s.onLastSeen != nil {
		s.onLastSeen(root)
	}
	at, ok := s.lastSeen[root]
	return at, ok, s.seenErr
}

// fakeProcs returns a fixed scan and records every Terminate.
type fakeProcs struct {
	list       []Proc
	terminated []Proc
}

func (p *fakeProcs) Scan(context.Context) ([]Proc, error) { return p.list, nil }

func (p *fakeProcs) Terminate(pr Proc) error {
	p.terminated = append(p.terminated, pr)
	return nil
}

// noGit is a GitRunner without git that fails the test if anything runs.
type noGit struct{ t *testing.T }

func (noGit) GitBinary() (string, bool) { return "", false }

func (g noGit) RunGit(context.Context, string, string, ...string) ([]byte, int, error) {
	g.t.Error("git ran although none was found")
	return nil, -1, nil
}

// failingGit is the real git except for the runs whose arguments start with
// prefix, which exit 128 as a broken repository would.
type failingGit struct {
	SystemGit
	prefix []string
}

func failGitOn(prefix ...string) failingGit { return failingGit{prefix: prefix} }

func (g failingGit) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	if len(args) >= len(g.prefix) && slices.Equal(args[:len(g.prefix)], g.prefix) {
		return nil, 128, &GitError{Args: args, Code: 128, Stderr: "fatal: injected failure"}
	}
	return g.SystemGit.RunGit(ctx, dir, bin, args...)
}
