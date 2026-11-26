package sessioncleanup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

var idleNow = time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)

// idleTree is a worktree root with a linked-worktree admin dir, every
// timestamp a week old.
type idleTree struct {
	t           *testing.T
	root, admin string
	store       *fakeStore
}

func newIdleTree(t *testing.T) *idleTree {
	t.Helper()
	base := t.TempDir()
	tr := &idleTree{t: t, root: filepath.Join(base, "wt"), admin: filepath.Join(base, "admin"), store: &fakeStore{}}
	for _, d := range []string{tr.root, filepath.Join(tr.admin, "logs")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"HEAD", "index", "logs/HEAD"} {
		tr.write(filepath.Join(tr.admin, f), "x")
		tr.touch(filepath.Join(tr.admin, f), idleNow.Add(-7*24*time.Hour))
	}
	tr.touch(tr.root, idleNow.Add(-7*24*time.Hour))
	return tr
}

func (tr *idleTree) write(path, body string) {
	tr.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		tr.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		tr.t.Fatal(err)
	}
}

func (tr *idleTree) touch(path string, at time.Time) {
	tr.t.Helper()
	if err := os.Chtimes(path, at, at); err != nil {
		tr.t.Fatal(err)
	}
}

// swiftBuild makes <root>/<rel> a SwiftPM build folder, old.
func (tr *idleTree) swiftBuild(rel string) string {
	tr.t.Helper()
	dir := filepath.Join(tr.root, rel)
	tr.write(filepath.Join(dir, "workspace-state.json"), "{}")
	tr.touch(dir, idleNow.Add(-7*24*time.Hour))
	return dir
}

func (tr *idleTree) deps() Deps {
	return Deps{DB: tr.store, Clock: func() time.Time { return idleNow }}
}

func (tr *idleTree) activity() time.Time {
	tr.t.Helper()
	at, err := lastActivity(context.Background(), tr.deps(), tr.root, tr.admin)
	if err != nil {
		tr.t.Fatalf("lastActivity: %v", err)
	}
	return at
}

func (tr *idleTree) idle() bool {
	return isIdle(context.Background(), tr.deps(), tr.root, tr.admin)
}

func TestIdle_QuietWorktreeIsIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	tr.swiftBuild("WatchtowerDesktop/.build")
	if !tr.idle() {
		t.Fatal("a week-old worktree is not idle")
	}
	if got, want := tr.activity(), idleNow.Add(-7*24*time.Hour); !got.Equal(want) {
		t.Fatalf("activity = %v, want %v", got, want)
	}
}

func TestIdle_EachAdminFileMovesActivity(t *testing.T) {
	t.Parallel()
	for _, f := range []string{"HEAD", "index", "logs/HEAD"} {
		tr := newIdleTree(t)
		recent := idleNow.Add(-time.Hour)
		tr.touch(filepath.Join(tr.admin, f), recent)
		if tr.idle() || !tr.activity().Equal(recent) {
			t.Fatalf("%s moved to %v: idle=%v activity=%v", f, recent, tr.idle(), tr.activity())
		}
	}
}

func TestIdle_LedgerSightingMovesActivity(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	recent := idleNow.Add(-2 * time.Hour)
	tr.store.lastSeen = map[string]time.Time{tr.root: recent}
	if tr.idle() || !tr.activity().Equal(recent) {
		t.Fatalf("a ledger sighting at %v: idle=%v activity=%v", recent, tr.idle(), tr.activity())
	}
	tr.store.lastSeen = map[string]time.Time{tr.root: idleNow.Add(-10 * 24 * time.Hour)}
	if !tr.idle() {
		t.Fatal("an old ledger sighting keeps the worktree busy")
	}
}

func TestIdle_UnreadableLedgerIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	tr.store.seenErr = errors.New("database is locked")
	if tr.idle() {
		t.Fatal("an unreadable ledger read as idle")
	}
	if at, err := lastActivity(context.Background(), tr.deps(), tr.root, tr.admin); err == nil || !at.Equal(idleNow) {
		t.Fatalf("lastActivity = %v, %v; want now and an error", at, err)
	}
}

func TestIdle_BuildFolderAtAnyDepthMovesActivity(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild("WatchtowerDesktop/.build")
	recent := idleNow.Add(-time.Hour)
	tr.touch(build, recent)
	if tr.idle() || !tr.activity().Equal(recent) {
		t.Fatalf("a nested build folder touched: idle=%v activity=%v", tr.idle(), tr.activity())
	}
}

func TestIdle_NestedIncrementalBuildCountsAsActivity(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild("WatchtowerDesktop/.build")
	deep := filepath.Join(build, "x", "y", "z")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	old := idleNow.Add(-7 * 24 * time.Hour)
	for _, d := range []string{build, filepath.Join(build, "x"), filepath.Join(build, "x", "y")} {
		tr.touch(d, old)
	}
	recent := idleNow.Add(-26 * time.Hour)
	tr.touch(deep, recent)
	if tr.idle() || !tr.activity().Equal(recent) {
		t.Fatalf("yesterday's incremental build in .build/x/y/z: idle=%v activity=%v", tr.idle(), tr.activity())
	}
}

func TestIdle_BuildWalkStopsAtTheActivityDepth(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild(".build")
	dir := build
	for i := 1; i <= buildActivityDepth+1; i++ {
		dir = filepath.Join(dir, "d"+strconv.Itoa(i))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	old := idleNow.Add(-7 * 24 * time.Hour)
	// d1..d8 old; d9 (too deep) recent.
	for d := filepath.Dir(dir); d != build; d = filepath.Dir(d) {
		tr.touch(d, old)
	}
	tr.touch(build, old)
	tr.touch(dir, idleNow.Add(-time.Minute))
	if !tr.idle() {
		t.Fatal("a directory deeper than buildActivityDepth counted")
	}
	tr.touch(filepath.Dir(dir), idleNow.Add(-time.Minute))
	if tr.idle() {
		t.Fatalf("the directory at depth %d did not count", buildActivityDepth)
	}
}

func TestIdle_FetchedPackageDirsAreIgnored(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild(".build")
	for _, name := range []string{"checkouts", "repositories", "artifacts", "SourcePackages"} {
		d := filepath.Join(build, name, "pkg")
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		tr.touch(d, idleNow.Add(-time.Minute))
		tr.touch(filepath.Dir(d), idleNow.Add(-time.Minute))
	}
	tr.touch(build, idleNow.Add(-7*24*time.Hour)) // creating the folders moved it
	if !tr.idle() {
		t.Fatal("a fetched-package directory counted as activity")
	}
}

func TestIdle_FilesInsideBuildAreNotStatted(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild(".build")
	f := filepath.Join(build, "log.txt")
	tr.write(f, "x")
	tr.touch(f, idleNow.Add(-time.Minute))
	tr.touch(build, idleNow.Add(-7*24*time.Hour))
	if !tr.idle() {
		t.Fatal("a file's mtime counted; only directories are stat-ed")
	}
}

func TestIdle_UnreadableStatIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	if err := os.Remove(filepath.Join(tr.admin, "HEAD")); err != nil {
		t.Fatal(err)
	}
	if tr.idle() {
		t.Fatal("a missing admin HEAD read as idle")
	}
	at, err := lastActivity(context.Background(), tr.deps(), tr.root, tr.admin)
	if err == nil || !at.Equal(idleNow) {
		t.Fatalf("lastActivity = %v, %v; want now and an error", at, err)
	}

	tr = newIdleTree(t)
	if os.Getuid() != 0 {
		build := tr.swiftBuild(".build")
		sub := filepath.Join(build, "x")
		if err := os.MkdirAll(filepath.Join(sub, "y"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(sub, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
		if tr.idle() {
			t.Fatal("an unreadable build sub-directory read as idle")
		}
	}
}

func TestIdle_MissingIndexAndLogAreNoActivity(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	for _, f := range []string{"index", "logs/HEAD"} {
		if err := os.Remove(filepath.Join(tr.admin, f)); err != nil {
			t.Fatal(err)
		}
	}
	if !tr.idle() {
		t.Fatal("a worktree with no index and no reflog is never idle")
	}
}

func TestIdle_BudgetOverrunIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	build := tr.swiftBuild(".build")
	for i := 0; i < 2*nestedClockEvery; i++ {
		d := filepath.Join(build, "d"+strconv.Itoa(i))
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
		tr.touch(d, idleNow.Add(-7*24*time.Hour))
	}
	at, err := lastActivityWithin(context.Background(), tr.deps(), tr.root, tr.admin, -time.Second)
	if err == nil || !at.Equal(idleNow) {
		t.Fatalf("over budget: %v, %v; want now and an error", at, err)
	}
	if _, err := lastActivity(context.Background(), tr.deps(), tr.root, tr.admin); err != nil {
		t.Fatalf("within budget: %v", err)
	}
}

func TestIdle_CancelledContextIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// Enough entries for the walk to look at the context.
	build := tr.swiftBuild(".build")
	for i := 0; i < 2*nestedClockEvery; i++ {
		if err := os.Mkdir(filepath.Join(build, "d"+strconv.Itoa(i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if isIdle(ctx, tr.deps(), tr.root, tr.admin) {
		t.Fatal("a cancelled walk read as idle")
	}
}

func TestIdle_IdleForBoundary(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	tr.touch(filepath.Join(tr.admin, "HEAD"), idleNow.Add(-idleFor+time.Second))
	if tr.idle() {
		t.Fatal("just under idleFor read as idle")
	}
	tr.touch(filepath.Join(tr.admin, "HEAD"), idleNow.Add(-idleFor))
	if !tr.idle() {
		t.Fatal("exactly idleFor is not idle")
	}
	tr.touch(filepath.Join(tr.admin, "HEAD"), idleNow.Add(time.Hour)) // clock skew: the future
	if tr.idle() {
		t.Fatal("a stamp in the future read as idle")
	}
}

func TestProj18_LanguageServerDoesNotKeepTheWorktree(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	root := f.pushedWork("wt", "feat/x")
	f.record(root, "feat/x")
	uid := os.Getuid()
	servers := []Proc{
		{PID: 601, PPID: 77, UID: uid, Exe: "/opt/homebrew/bin/gopls", Cwd: root},
		{PID: 602, PPID: 1, UID: uid, Exe: filepath.Join(root, ".build", "bin", "sourcekit-lsp"), Cwd: root},
		{PID: 603, PPID: 1, UID: uid, Exe: "/usr/bin/clangd", Cwd: root},
		{PID: 604, PPID: 1, UID: uid, Exe: "/x/rust-analyzer", Cwd: root},
		{PID: 605, PPID: 1, UID: uid, Exe: "/x/jdtls", Cwd: root},
		{PID: 606, PPID: 1, UID: uid, Exe: "/x/lua-language-server", Cwd: root},
		{PID: 607, PPID: 1, UID: uid, Exe: "/x/zls", Cwd: root},
	}
	for _, p := range servers {
		f.procs.list = []Proc{p}
		wantItem(t, f.plan(Request{}), "worktree:"+root, ActionRemove, "")
		f.procs.list = []Proc{p}
		wantItem(t, f.plan(Request{Sweep: true}), "worktree:"+root, ActionRemove, "")
	}
	f.procs.list = servers
	p := f.plan(Request{})
	for _, it := range p.Items {
		if it.Kind == KindProcess {
			t.Fatalf("a language server is planned for a signal: %+v", it)
		}
	}
	if len(f.procs.terminated) != 0 {
		t.Fatalf("a plan signalled %v", f.procs.terminated)
	}

	// Under node or python, or with an unknown executable, it still keeps the worktree.
	for _, p := range []Proc{
		{PID: 610, PPID: 1, UID: uid, Exe: "/usr/local/bin/node", Cwd: root, Name: "tsserver"},
		{PID: 611, PPID: 1, UID: uid, Exe: "/usr/bin/python3", Cwd: root, Name: "pylsp"},
		{PID: 612, PPID: 1, UID: uid, Name: "gopls", Cwd: root}, // comm alone is never trusted
	} {
		f.procs.list = []Proc{p}
		wantItem(t, f.plan(Request{}), "worktree:"+root, ActionKeep, ReasonProcessRunning)
	}
}

func TestProj18_LanguageServerIsNeverAnOrphanToSignal(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	uid := os.Getuid()
	orphans, blockers := OrphansIn([]Proc{
		{PID: 1, PPID: 1, UID: uid, Exe: filepath.Join(root, "bin", "gopls"), Cwd: root},
	}, []string{root}, 99)
	if len(orphans) != 0 || len(blockers) != 0 {
		t.Fatalf("orphans %v blockers %v; want neither", orphans, blockers)
	}
}

func TestIdle_ExpiredBudgetOnATinyTreeIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	tr.swiftBuild(".build")
	at, err := lastActivityWithin(context.Background(), tr.deps(), tr.root, tr.admin, -time.Second)
	if err == nil || !at.Equal(idleNow) {
		t.Fatalf("expired budget: %v, %v; want now and an error", at, err)
	}
	if _, err := buildActivity(context.Background(), filepath.Join(tr.root, ".build"), -time.Second); err == nil {
		t.Fatal("buildActivity succeeded over an expired budget")
	}
}

func TestIdle_CancelledContextOnATinyTreeIsNotIdle(t *testing.T) {
	t.Parallel()
	tr := newIdleTree(t)
	tr.swiftBuild(".build")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if isIdle(ctx, tr.deps(), tr.root, tr.admin) {
		t.Fatal("a cancelled measure read as idle")
	}
}

func TestIdle_UnreadableDirectoryUnderTheWorktreeIsNotIdle(t *testing.T) {
	t.Parallel()
	if os.Getuid() == 0 {
		t.Skip("root reads everything")
	}
	tr := newIdleTree(t)
	tr.swiftBuild(".build")
	sub := filepath.Join(tr.root, "pkg")
	if err := os.MkdirAll(filepath.Join(sub, "inner"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(sub, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
	if tr.idle() {
		t.Fatal("a directory that cannot be looked at read as idle")
	}
}
