package reviewmap

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"watchtower/internal/gitbin"
	"watchtower/internal/reviewdiff"
)

// laneRepo is a synthetic repository for the lane attribution.
type laneRepo struct {
	t   *testing.T
	dir string
	bin string
}

func newLaneRepo(t *testing.T) *laneRepo {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git not installed")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.com")
	r := &laneRepo{t: t, dir: t.TempDir(), bin: bin}
	r.git("init", "-q", "-b", "main")
	r.commit("init", "README.md")
	return r
}

func (r *laneRepo) git(args ...string) string {
	r.t.Helper()
	cmd := exec.Command(r.bin, args...)
	cmd.Dir = r.dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// commit writes each path with fresh content and commits it with subject.
func (r *laneRepo) commit(subject string, paths ...string) {
	r.t.Helper()
	for _, p := range paths {
		full := filepath.Join(r.dir, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			r.t.Fatal(err)
		}
		f, err := os.OpenFile(full, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			r.t.Fatal(err)
		}
		if _, err := f.WriteString(subject + "\n"); err != nil {
			r.t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			r.t.Fatal(err)
		}
	}
	r.git("add", "-A")
	r.git("commit", "-q", "--allow-empty", "-m", subject)
}

func (r *laneRepo) checkout(args ...string) {
	r.t.Helper()
	r.git(append([]string{"checkout", "-q"}, args...)...)
}
func (r *laneRepo) merge(branch, subject string) {
	r.t.Helper()
	r.git("merge", "-q", "--no-ff", "-m", subject, branch)
}
func (r *laneRepo) rev(spec string) string { r.t.Helper(); return r.git("rev-parse", spec) }

func (r *laneRepo) open() *reviewdiff.Repo {
	r.t.Helper()
	repo, err := reviewdiff.Open(r.dir, nil)
	if err != nil {
		r.t.Fatal(err)
	}
	return repo
}

type fakeTitles struct {
	t     LaneTitles
	calls int
	got   [3]any
}

func (f *fakeTitles) Titles(branches, keys []string, refs []int64) LaneTitles {
	f.calls++
	f.got = [3]any{branches, keys, refs}
	return f.t
}

func newFakeTitles() *fakeTitles {
	return &fakeTitles{t: LaneTitles{
		BranchTargets: map[string]TargetTitle{"feature/a": {ID: 41, Text: "Lane A target"}},
		Jira:          map[string]string{"ABC-7": "B summary", "ABC-9": "Nine"},
		JiraProjects:  map[string]bool{"ABC": true},
		BoardRefs:     map[int64]TargetTitle{1234: {ID: 1234, Text: "Board item"}},
	}}
}

// bigBranch builds feature/big off main:
//   - lane feature/a (two commits; one touches "dir with space/ü.go");
//   - nested integration lane feature/n-ZZ-3 merging feature/n1 by a PR
//     merge, with direct commits: untagged, a kept unsynced key (ZZ-3, in
//     the branch name), a dropped one (ZZ-4), a scope;
//   - a base sync (main merged in);
//   - lane feature/b-ABC-7;
//   - tagged and untagged direct commits on the top branch;
//   - a fast-forward to a merge of feature/big into feature/c.
//
// shared/count.go: two commits of lane a, one of lane b → a wins on count.
// shared/tie.go: one commit each, b later → b wins the tie.
func bigBranch(t *testing.T) (*laneRepo, string) {
	r := newLaneRepo(t)
	r.checkout("-b", "feature/big")

	r.checkout("-b", "feature/a")
	r.commit("a one", "a/x.go", "shared/count.go", "shared/tie.go")
	r.commit("a two", "a/y.go", "shared/count.go", "dir with space/ü.go")
	r.checkout("feature/big")
	r.merge("feature/a", "Merge branch 'feature/a' into feature/big")

	r.checkout("-b", "feature/n-ZZ-3")
	r.checkout("-b", "feature/n1")
	r.commit("n1 work", "n/n1.go")
	r.checkout("feature/n-ZZ-3")
	r.merge("feature/n1", "Merge pull request #12 from acme/feature/n1")
	r.commit("untagged on n", "n/direct.go")
	r.commit("ZZ-3 kept by the branch name", "n/zz3.go")
	r.commit("ZZ-4 dropped", "n/zz4.go")
	r.commit("fix(core): scoped", "n/core.go")
	r.checkout("feature/big")
	r.merge("feature/n-ZZ-3", "Merge remote-tracking branch 'origin/feature/n-ZZ-3'")

	r.checkout("main")
	r.commit("main moves", "m/main.go")
	r.checkout("feature/big")
	r.merge("main", "Merge branch 'main' into feature/big")

	r.checkout("-b", "feature/b-ABC-7")
	r.commit("b one", "b/z.go", "shared/count.go", "shared/tie.go")
	r.checkout("feature/big")
	r.merge("feature/b-ABC-7", "Merge branch 'feature/b-ABC-7' into feature/big")

	r.commit("ABC-9 synced key", "d/jira.go")
	r.commit("ABC-8 synced project, unknown key", "d/abc8.go")
	r.commit("XYZ-1 unsynced key", "d/xyz.go")
	r.commit("UTF-8 handling (T3)", "d/plan.go")
	r.commit("polish #1234", "d/board.go")
	r.commit("polish #999", "d/noboard.go")
	r.commit("feat(review): scoped", "d/scope.go")
	r.commit("plain", "d/plain.go")

	r.checkout("-b", "feature/c")
	r.commit("c work", "c/c1.go")
	r.checkout("feature/big")
	r.commit("big moves on", "d/ff.go")
	r.checkout("feature/c")
	r.merge("feature/big", "Merge branch 'feature/big' into feature/c")
	r.checkout("feature/big")
	r.git("merge", "-q", "--ff-only", "feature/c")
	return r, r.rev("main")
}

func TestAttribute_SyntheticBranch(t *testing.T) {
	r, mainTip := bigBranch(t)
	head := r.rev("HEAD")
	base := r.git("merge-base", "HEAD", "main")
	// An uncommitted file has no commit and so no lane.
	if err := os.WriteFile(filepath.Join(r.dir, "u.go"), []byte("package u\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	titles := newFakeTitles()
	a, err := Attribute(context.Background(), r.open(), base, head, "feature/big", mainTip, titles, 20*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if a.Partial {
		t.Error("a complete walk is not partial")
	}
	if titles.calls != 1 {
		t.Errorf("Titles called %d times, want once", titles.calls)
	}
	wantLane := map[string]string{
		"a/x.go":              "feature/a",
		"a/y.go":              "feature/a",
		"dir with space/ü.go": "feature/a",
		"shared/count.go":     "feature/a", // 2 commits beat 1
		"shared/tie.go":       "feature/b-ABC-7",
		"b/z.go":              "feature/b-ABC-7",
		"n/n1.go":             "feature/n1",
		"n/direct.go":         "feature/n-ZZ-3", // untagged on a nested integration lane
		"n/zz3.go":            "ZZ-3",
		"n/zz4.go":            "feature/n-ZZ-3",
		"n/core.go":           "core",
		"d/jira.go":           "ABC-9",
		"d/plan.go":           "T3",
		"d/board.go":          "#1234",
		"d/scope.go":          "review",
		"d/ff.go":             "feature/c", // named by `into`
	}
	if !reflect.DeepEqual(a.FileLane, wantLane) {
		t.Errorf("FileLane:\n got %v\nwant %v", a.FileLane, wantLane)
	}
	wantAlso := map[string][]string{
		"shared/count.go": {"feature/b-ABC-7"},
		"shared/tie.go":   {"feature/a"},
	}
	if !reflect.DeepEqual(a.Also, wantAlso) {
		t.Errorf("Also:\n got %v\nwant %v", a.Also, wantAlso)
	}
	for _, unlaned := range []string{"m/main.go", "d/abc8.go", "d/xyz.go", "d/noboard.go", "d/plain.go", "c/c1.go", "u.go", "README.md"} {
		if l, ok := a.FileLane[unlaned]; ok {
			t.Errorf("%s has lane %q, want none", unlaned, l)
		}
	}
	if _, ok := a.Lanes["feature/big"]; ok {
		t.Error("the fast-forward merge was named by its source, not by `into`")
	}
	if _, ok := a.Lanes["main"]; ok {
		t.Error("a base sync became a lane")
	}
	wantLanes := map[string]Lane{
		"feature/a":       {Name: "feature/a", Branch: "feature/a", Title: "Lane A target", TargetID: 41},
		"feature/b-ABC-7": {Name: "feature/b-ABC-7", Branch: "feature/b-ABC-7", Title: "B summary", JiraKey: "ABC-7"},
		"feature/n-ZZ-3":  {Name: "feature/n-ZZ-3", Branch: "feature/n-ZZ-3", Title: "feature/n-ZZ-3"},
		"feature/n1":      {Name: "feature/n1", Branch: "feature/n1", Title: "feature/n1"},
		"feature/c":       {Name: "feature/c", Branch: "feature/c", Title: "feature/c"},
		"ZZ-3":            {Name: "ZZ-3", Title: "ZZ-3"},
		"core":            {Name: "core", Title: "core"},
		"ABC-9":           {Name: "ABC-9", Title: "Nine", JiraKey: "ABC-9"},
		"T3":              {Name: "T3", Title: "T3"},
		"#1234":           {Name: "#1234", Title: "Board item", TargetID: 1234},
		"review":          {Name: "review", Title: "review"},
	}
	if !reflect.DeepEqual(a.Lanes, wantLanes) {
		t.Errorf("Lanes:\n got %+v\nwant %+v", a.Lanes, wantLanes)
	}
	wantAsked := [3]any{
		[]string{"feature/a", "feature/b-ABC-7", "feature/c", "feature/n-ZZ-3", "feature/n1"},
		[]string{"ABC-7", "ABC-8", "ABC-9", "UTF-8", "XYZ-1", "ZZ-3", "ZZ-4"},
		[]int64{999, 1234},
	}
	if !reflect.DeepEqual(titles.got, wantAsked) {
		t.Errorf("Titles asked:\n got %v\nwant %v", titles.got, wantAsked)
	}
}

func TestAttribute_EmptyHeadIsPartialWithNoLanes(t *testing.T) {
	r := newLaneRepo(t)
	titles := newFakeTitles()
	a, err := Attribute(context.Background(), r.open(), r.rev("HEAD"), "", "", "", titles, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Partial || len(a.FileLane) != 0 || len(a.Lanes) != 0 || len(a.Also) != 0 {
		t.Fatalf("attribution = %+v, want partial and empty", a)
	}
	if titles.calls != 0 {
		t.Error("no walk, no title lookup")
	}
}

func TestAttribute_BudgetSpentIsPartialAndEmpty(t *testing.T) {
	r := newLaneRepo(t)
	r.commit("one", "x.go")
	a, err := Attribute(context.Background(), r.open(), r.rev("HEAD~1"), r.rev("HEAD"),
		"", "", newFakeTitles(), time.Nanosecond)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Partial || len(a.FileLane) != 0 || len(a.Lanes) != 0 {
		t.Fatalf("attribution = %+v, want partial and empty", a)
	}
}

func TestAttribute_DoneContextIsAnError(t *testing.T) {
	r := newLaneRepo(t)
	r.commit("one", "x.go")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Attribute(ctx, r.open(), r.rev("HEAD~1"), r.rev("HEAD"),
		"", "", newFakeTitles(), time.Minute); err == nil {
		t.Fatal("a cancelled caller got an attribution")
	}
}

func TestAttribute_BoundsLeaveTheRestUnlaned(t *testing.T) {
	r, mainTip := bigBranch(t)
	base := r.git("merge-base", "HEAD", "main")
	// Four commits of the top walk (the fast-forward merge, "c work",
	// "plain", the scoped commit) spend the bound before any lane is read.
	a, err := attribute(context.Background(), r.open(), base, r.rev("HEAD"), "feature/big", mainTip,
		newFakeTitles(), time.Minute, 4, maxWalkLanes)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Partial {
		t.Error("a walk cut by the commit bound is partial")
	}
	if want := map[string]string{"d/scope.go": "review"}; !reflect.DeepEqual(a.FileLane, want) {
		t.Errorf("FileLane = %v, want %v", a.FileLane, want)
	}

	// One lane: the oldest lane merge is read, the later ones are not.
	a, err = attribute(context.Background(), r.open(), base, r.rev("HEAD"), "feature/big", mainTip,
		newFakeTitles(), time.Minute, maxWalkCommits, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !a.Partial {
		t.Error("a walk cut by the lane bound is partial")
	}
	if a.FileLane["a/x.go"] != "feature/a" {
		t.Errorf("the first lane is walked: %v", a.FileLane)
	}
	for _, f := range []string{"n/n1.go", "b/z.go", "d/ff.go"} {
		if l, ok := a.FileLane[f]; ok {
			t.Errorf("%s has lane %q past the lane bound", f, l)
		}
	}
	if a.FileLane["d/jira.go"] != "ABC-9" {
		t.Error("tagged direct commits keep their lanes past the lane bound")
	}
}

func TestMergeLaneName(t *testing.T) {
	for _, c := range []struct{ subject, walked, want string }{
		{"Merge pull request #57 from acme/feature/x-y", "", "feature/x-y"},
		{"Merge branch 'feature/a'", "", "feature/a"},
		{"Merge branch 'feature/a' into feature/big", "feature/big", "feature/a"},
		{"Merge branch 'feature/big' into feature/c", "feature/big", "feature/c"},
		{"Merge branch 'feature/big' into 'feature/c'", "feature/big", "feature/c"},
		{"Merge branch 'feature/big'", "feature/big", "feature/big"},
		{"Merge remote-tracking branch 'origin/lane/t1'", "", "lane/t1"},
		{"Merge origin/lane/t2: conflicts resolved", "", "lane/t2"},
		{"Merge lane/t3 into feature", "", "lane/t3"},
		{"Merged everything", "", "?"},
		{"fix: things", "", "?"},
	} {
		if got := mergeLaneName(c.subject, c.walked); got != c.want {
			t.Errorf("mergeLaneName(%q, %q) = %q, want %q", c.subject, c.walked, got, c.want)
		}
	}
}

func TestCommitTag(t *testing.T) {
	titles := newFakeTitles().t
	for _, c := range []struct{ subject, branch, want string }{
		{"ABC-9: fix", "", "ABC-9"},
		{"ABC-8: unknown issue of a synced project", "", ""},
		{"QQ-5 in the branch", "feature/QQ-5-x", "QQ-5"},
		{"QQ-5 not in the branch", "feature/x", ""},
		{"UTF-8 and ABC-9", "", "ABC-9"}, // the first valid key wins
		{"close #1234 and #999", "", "#1234"},
		{"see #999", "", ""},
		{"#5 too short", "", ""},
		{"step (P2a) done", "", "P2a"},
		{"feat(review)!: breaking", "", "review"},
		{"ABC-9 (T3) feat(x): all", "", "ABC-9"}, // Jira before plan tag
		{"#1234 (T3)", "", "#1234"},              // board before plan tag
		{"chore: untagged", "", ""},
	} {
		if got := commitTag(c.subject, c.branch, titles); got != c.want {
			t.Errorf("commitTag(%q, %q) = %q, want %q", c.subject, c.branch, got, c.want)
		}
	}
}
