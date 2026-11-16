package watchman

import (
	"context"
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

var gitT0 = time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)

type testRepo struct {
	t   *testing.T
	dir string
}

func newTestRepo(t *testing.T) *testRepo {
	t.Helper()
	r := &testRepo{t: t, dir: t.TempDir()}
	r.git(gitT0, "init", "-q", "-b", "main")
	return r
}

func (r *testRepo) git(at time.Time, args ...string) {
	r.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", r.dir, "-c", "user.name=Owner", "-c", "user.email=owner@example.com", "-c", "commit.gpgsign=false"}, args...)...)
	stamp := at.Format(time.RFC3339)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+stamp, "GIT_COMMITTER_DATE="+stamp)
	if out, err := cmd.CombinedOutput(); err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// commit writes each path with fresh content and commits with message msg.
func (r *testRepo) commit(at time.Time, msg string, paths ...string) {
	r.t.Helper()
	for _, p := range paths {
		full := filepath.Join(r.dir, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			r.t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(msg+at.String()), 0o600); err != nil {
			r.t.Fatal(err)
		}
	}
	r.git(at, "add", "-A")
	r.git(at, "commit", "-q", "-m", msg)
}

const claudeTrailer = "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"

func day(n int) time.Time { return gitT0.Add(time.Duration(n) * 24 * time.Hour) }

func TestGitSource_OwnerRewriteOfAgentWork(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "initial", "a.go", "b.go")
	r.commit(day(1), "feat: add parser"+claudeTrailer, "a.go")
	r.commit(day(2), "rewrite the parser loop", "a.go")
	r.commit(day(2).Add(time.Hour), "touch only b", "b.go") // no agent change of b.go
	r.commit(day(20), "late edit of a", "a.go")             // agent commit is 19 days old
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	ps, next, done, err := GitSource(ExecGit).Next(context.Background(), d, wb, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if !done || next == "" {
		t.Fatalf("done=%v next=%q", done, next)
	}
	if len(ps) != 1 {
		t.Fatalf("got %d precedents, want 1: %+v", len(ps), ps)
	}
	p := ps[0]
	if p.Source != "git" || p.Choice != "rewrote" || p.OwnerWords != "rewrite the parser loop" || p.Category != "" ||
		!p.DecidedAt.Equal(day(2)) || !strings.HasPrefix(p.SourceKey, "commit:") {
		t.Errorf("precedent = %+v", p)
	}
	if !strings.Contains(p.Situation, "feat: add parser") || !strings.Contains(p.Situation, "a.go") || strings.Contains(p.Situation, "b.go") {
		t.Errorf("situation = %q", p.Situation)
	}
}

func TestGitSource_TestsCategory(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "add tests"+claudeTrailer, "x_test.go", "WatchtowerDesktop/Tests/FooTests.swift")
	r.commit(day(1), "fix the tests", "x_test.go", "WatchtowerDesktop/Tests/FooTests.swift")
	d := openWatchmanDB(t)
	ps, _, _, err := GitSource(ExecGit).Next(context.Background(), d, addWorkbench(t, d, r.dir), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 1 || ps[0].Category != "tests" {
		t.Fatalf("got %+v", ps)
	}
}

func TestGitSource_SkipsAgentCommits(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "agent work"+claudeTrailer, "a.go")
	r.commit(day(1), "lower case trailer\n\nCo-authored-by: Claude <noreply@anthropic.com>", "a.go")
	r.commit(day(2), "codex work\n\nCo-Authored-By: Codex <codex@openai.com>", "a.go") // leak-check:allow (the Codex trailer under test)
	r.commit(day(3), "Squashed PR (#12)\n\n* step one\n\n* step two\n\nCo-authored-by: Claude Opus <noreply@anthropic.com>", "a.go")
	r.commit(day(4), "owner fix", "a.go")
	d := openWatchmanDB(t)
	ps, _, _, err := GitSource(ExecGit).Next(context.Background(), d, addWorkbench(t, d, r.dir), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 1 || ps[0].OwnerWords != "owner fix" {
		t.Fatalf("got %+v", ps)
	}
	for _, sj := range []string{"agent work", "lower case trailer", "codex work", "Squashed PR (#12)"} {
		if !strings.Contains(ps[0].Situation, sj) {
			t.Errorf("situation %q misses agent commit %q", ps[0].Situation, sj)
		}
	}
}

func TestGitSource_NotARepo(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	ps, next, done, err := GitSource(ExecGit).Next(context.Background(), d, wb, "", 10)
	if err != nil || !done || len(ps) != 0 || next != "" {
		t.Fatalf("ps=%v next=%q done=%v err=%v", ps, next, done, err)
	}
}

func TestGitSource_MergedPRs(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "initial", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	for _, s := range []db.PRState{
		{WorkbenchID: wb, Ref: "pr:12", State: "merged", PRNumber: sql.NullInt64{Int64: 12, Valid: true}, Title: "Add parser", MergedAt: "2026-10-02T09:30:00Z"},
		{WorkbenchID: wb, Ref: "branch:feat/parser", State: "merged", PRNumber: sql.NullInt64{Int64: 12, Valid: true}, Title: "Add parser", MergedAt: "2026-10-02T09:30:00Z"},
		{WorkbenchID: wb, Ref: "pr:13", State: "open", PRNumber: sql.NullInt64{Int64: 13, Valid: true}, Title: "Open one"},
		{WorkbenchID: wb, Ref: "pr:14", State: "closed", PRNumber: sql.NullInt64{Int64: 14, Valid: true}, Title: "Closed one"},
	} {
		if err := d.UpsertPRState(s); err != nil {
			t.Fatal(err)
		}
	}
	ps, _, done, err := GitSource(ExecGit).Next(context.Background(), d, wb, "", 10)
	if err != nil || !done {
		t.Fatalf("done=%v err=%v", done, err)
	}
	if len(ps) != 1 {
		t.Fatalf("got %d precedents, want 1: %+v", len(ps), ps)
	}
	p := ps[0]
	want := time.Date(2026, 10, 2, 9, 30, 0, 0, time.UTC)
	if p.Category != "finish" || p.Choice != "merged" || p.SourceKey != "merge:pr:12" || p.Situation != "PR #12: Add parser" || !p.DecidedAt.Equal(want) {
		t.Errorf("precedent = %+v", p)
	}
}

func TestGitSource_CursorNewestFirst(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "agent"+claudeTrailer, "a.go")
	r.commit(day(1), "owner one", "a.go")
	r.commit(day(2), "owner two", "a.go")
	r.commit(day(3), "owner three", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	src := GitSource(ExecGit)
	ctx := context.Background()
	ps, c, done, err := src.Next(ctx, d, wb, "", 2)
	if err != nil || done || len(ps) != 2 || ps[0].OwnerWords != "owner three" || ps[1].OwnerWords != "owner two" {
		t.Fatalf("page 1: %+v done=%v err=%v", ps, done, err)
	}
	store(t, d, ps)
	r.commit(day(4), "owner four", "a.go")
	ps, c, done, err = src.Next(ctx, d, wb, c, 2)
	if err != nil || done || len(ps) != 2 || ps[0].OwnerWords != "owner four" || ps[1].OwnerWords != "owner one" {
		t.Fatalf("page 2: %+v done=%v err=%v", ps, done, err)
	}
	store(t, d, ps)
	ps, _, done, err = src.Next(ctx, d, wb, c, 2)
	if err != nil || !done || len(ps) != 0 {
		t.Fatalf("page 3: %+v done=%v err=%v", ps, done, err)
	}
}

// store upserts emitted precedents as the runner would after labelling.
func store(t *testing.T, d *db.DB, ps []db.WatchmanPrecedent) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for i := range ps {
		if ps[i].Category == "" {
			ps[i].Category = "design"
		}
	}
	if err := d.UpsertWatchmanPrecedents(tx, ps); err != nil {
		_ = tx.Rollback()
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func ownerWords(ps []db.WatchmanPrecedent) []string {
	var w []string
	for _, p := range ps {
		w = append(w, p.OwnerWords)
	}
	return w
}

func TestGitSource_LateMergedCommitStillEmitted(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "agent work"+claudeTrailer, "a.go", "b.go")
	r.git(day(0), "branch", "wt")
	r.commit(day(3), "owner on main", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	src := GitSource(ExecGit)
	ctx := context.Background()
	ps, c, done, err := src.Next(ctx, d, wb, "", 10)
	if err != nil || !done || len(ps) != 1 || ps[0].OwnerWords != "owner on main" {
		t.Fatalf("first: %+v done=%v err=%v", ps, done, err)
	}
	store(t, d, ps)
	// A worktree branch with an owner commit dated before hi merges late.
	r.git(day(2), "checkout", "-q", "wt")
	r.commit(day(2), "owner on branch", "b.go")
	r.git(day(2), "checkout", "-q", "main")
	r.git(day(5), "merge", "-q", "--no-ff", "-m", "merge wt", "wt")
	ps, c, done, err = src.Next(ctx, d, wb, c, 10)
	if err != nil || !done {
		t.Fatalf("second: done=%v err=%v", done, err)
	}
	if got := ownerWords(ps); len(got) != 1 || got[0] != "owner on branch" {
		t.Fatalf("second = %v", got)
	}
	store(t, d, ps)
	ps, _, _, err = src.Next(ctx, d, wb, c, 10)
	if err != nil || len(ps) != 0 {
		t.Fatalf("third: %+v err=%v", ps, err)
	}
}

func TestGitSource_LateCachedMergeStillEmitted(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "initial", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	pr := func(n int64, merged time.Time) db.PRState {
		return db.PRState{WorkbenchID: wb, Ref: "pr:" + strconv.FormatInt(n, 10), State: "merged",
			PRNumber: sql.NullInt64{Int64: n, Valid: true}, Title: "PR", MergedAt: merged.Format(time.RFC3339)}
	}
	if err := d.UpsertPRState(pr(2, day(10))); err != nil {
		t.Fatal(err)
	}
	src := GitSource(ExecGit)
	ctx := context.Background()
	ps, c, _, err := src.Next(ctx, d, wb, "", 10)
	if err != nil || len(ps) != 1 {
		t.Fatalf("first: %+v err=%v", ps, err)
	}
	store(t, d, ps)
	// PR 1 merged earlier but its state is cached only now.
	if err := d.UpsertPRState(pr(1, day(8))); err != nil {
		t.Fatal(err)
	}
	ps, _, _, err = src.Next(ctx, d, wb, c, 10)
	if err != nil || len(ps) != 1 || ps[0].SourceKey != "merge:pr:1" {
		t.Fatalf("second: %+v err=%v", ps, err)
	}
}

func TestGitSource_LateFindOfferedOnce(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "agent work"+claudeTrailer, "a.go", "b.go")
	r.git(day(0), "branch", "wt")
	r.commit(day(3), "owner on main", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	src := GitSource(ExecGit)
	ctx := context.Background()
	ps, c, _, err := src.Next(ctx, d, wb, "", 10)
	if err != nil || len(ps) != 1 {
		t.Fatalf("first: %+v err=%v", ps, err)
	}
	store(t, d, ps)
	r.git(day(2), "checkout", "-q", "wt")
	r.commit(day(2), "owner on branch", "b.go")
	r.git(day(2), "checkout", "-q", "main")
	r.git(day(5), "merge", "-q", "--no-ff", "-m", "merge wt", "wt")
	ps, c, _, err = src.Next(ctx, d, wb, c, 10)
	if err != nil || len(ps) != 1 || ps[0].OwnerWords != "owner on branch" {
		t.Fatalf("second: %+v err=%v", ps, err)
	}
	// The learner could not label it: marked skipped, not stored.
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := d.MarkWatchmanSkippedKeys(tx, "git", []string{ps[0].SourceKey}, day(6)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	ps, _, _, err = src.Next(ctx, d, wb, c, 10)
	if err != nil || len(ps) != 0 {
		t.Fatalf("third: %+v err=%v", ps, err)
	}
}

func TestGitSource_LateFindsCountTowardLimit(t *testing.T) {
	r := newTestRepo(t)
	r.commit(day(0), "initial", "a.go")
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, r.dir)
	pr := func(n int64, merged time.Time) db.PRState {
		return db.PRState{WorkbenchID: wb, Ref: "pr:" + strconv.FormatInt(n, 10), State: "merged",
			PRNumber: sql.NullInt64{Int64: n, Valid: true}, Title: "PR", MergedAt: merged.Format(time.RFC3339)}
	}
	if err := d.UpsertPRState(pr(9, day(10))); err != nil {
		t.Fatal(err)
	}
	src := GitSource(ExecGit)
	ctx := context.Background()
	ps, c, _, err := src.Next(ctx, d, wb, "", 10)
	if err != nil || len(ps) != 1 {
		t.Fatalf("first: %+v err=%v", ps, err)
	}
	store(t, d, ps)
	for n := int64(1); n <= 3; n++ { // three merges cached late
		if err := d.UpsertPRState(pr(n, day(int(n)))); err != nil {
			t.Fatal(err)
		}
	}
	ps, _, done, err := src.Next(ctx, d, wb, c, 2)
	if err != nil || done || len(ps) != 2 {
		t.Fatalf("second: %d rows done=%v err=%v", len(ps), done, err)
	}
}
