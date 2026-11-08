package reviewdiff

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// historyRepo: main = init; branch lane = two commits (one touching a path
// with a space and a non-ASCII letter), merged into main with --no-ff, then
// one more commit on main. Returns the dir and the commit ids by name.
func historyRepo(t *testing.T) (string, map[string]string) {
	t.Helper()
	dir := newRepo(t)
	rev := func(spec string) string { return strings.TrimSpace(gitIn(t, dir, "rev-parse", spec)) }
	ids := map[string]string{"init": rev("HEAD")}
	gitIn(t, dir, "checkout", "-q", "-b", "lane")
	writeFile(t, dir, "dir with space/ü.go", "package x\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "lane one")
	ids["l1"] = rev("HEAD")
	writeFile(t, dir, "b.go", "package b\n")
	writeFile(t, dir, "a.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "lane two")
	ids["l2"] = rev("HEAD")
	gitIn(t, dir, "checkout", "-q", "main")
	gitIn(t, dir, "merge", "-q", "--no-ff", "-m", "Merge branch 'lane'", "lane")
	ids["merge"] = rev("HEAD")
	writeFile(t, dir, "c.go", "package c\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "--allow-empty", "-m", "after")
	ids["after"] = rev("HEAD")
	gitIn(t, dir, "commit", "-q", "--allow-empty", "--allow-empty-message", "-m", "")
	return dir, ids
}

func TestFirstParentWalk_ParentsSubjectsAndExclude(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	got, err := r.FirstParentWalk(ctx, ids["after"], []string{ids["init"]}, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := []Commit{
		{SHA: ids["after"], Parents: []string{ids["merge"]}, Subject: "after"},
		{SHA: ids["merge"], Parents: []string{ids["init"], ids["l2"]}, Subject: "Merge branch 'lane'"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("walk = %+v\nwant %+v", got, want)
	}
	got, err = r.FirstParentWalk(ctx, ids["l2"], []string{ids["init"]}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].SHA != ids["l2"] || got[0].Subject != "lane two" {
		t.Fatalf("limited walk = %+v", got)
	}
}

func TestFirstParentWalk_EmptySubject(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	got, err := r.FirstParentWalk(context.Background(), "HEAD", []string{ids["after"]}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Subject != "" || !reflect.DeepEqual(got[0].Parents, []string{ids["after"]}) {
		t.Fatalf("walk = %+v", got)
	}
}

func TestCommitFiles_NULSeparatedPathsAndNoMerges(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	got, err := r.CommitFiles(ctx, ids["l2"], []string{ids["init"]}, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		ids["l1"]: {"dir with space/ü.go"},
		ids["l2"]: {"a.go", "b.go"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("files = %q\nwant %q", got, want)
	}
	// The first-parent walk of main lists no merge and no lane commit;
	// a commit with no file change is present with no files.
	got, err = r.CommitFiles(ctx, ids["after"], []string{ids["init"]}, 0)
	if err != nil {
		t.Fatal(err)
	}
	want = map[string][]string{ids["after"]: {"c.go"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("files = %q\nwant %q", got, want)
	}
	got, err = r.CommitFiles(ctx, ids["l2"], []string{ids["init"]}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[ids["l2"]] == nil {
		t.Fatalf("limited files = %q", got)
	}
}

func TestIsAncestor(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{ids["l1"], ids["after"], true},
		{ids["after"], ids["l1"], false},
		{ids["init"], ids["init"], true},
	} {
		got, err := r.IsAncestor(ctx, c.a, c.b)
		if err != nil {
			t.Fatal(err)
		}
		if got != c.want {
			t.Errorf("IsAncestor(%s, %s) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
	if _, err := r.IsAncestor(ctx, ids["init"], strings.Repeat("0", 40)); err == nil {
		t.Error("an unknown commit is an error, not a no")
	}
}

func TestHistory_RefusesOptionLikeRevisions(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	if _, err := r.FirstParentWalk(ctx, "--all", nil, 0); err == nil {
		t.Error("walk accepted an option as the tip")
	}
	if _, err := r.FirstParentWalk(ctx, ids["after"], []string{"--all"}, 0); err == nil {
		t.Error("walk accepted an option as an exclusion")
	}
	if _, err := r.CommitFiles(ctx, "", nil, 0); err == nil {
		t.Error("files accepted an empty tip")
	}
	if _, err := r.IsAncestor(ctx, "-x", ids["after"]); err == nil {
		t.Error("is-ancestor accepted an option")
	}
}

func TestHistory_DoneContextIsAnError(t *testing.T) {
	dir, ids := historyRepo(t)
	r := openRepo(t, dir)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := r.FirstParentWalk(ctx, ids["after"], nil, 0); err == nil {
		t.Error("walk on a done context")
	}
	if _, err := r.CommitFiles(ctx, ids["after"], nil, 0); err == nil {
		t.Error("files on a done context")
	}
	if _, err := r.IsAncestor(ctx, ids["init"], ids["after"]); err == nil {
		t.Error("is-ancestor on a done context")
	}
}

func TestCommitFiles_RootCommitDespiteShowRootOff(t *testing.T) {
	dir, ids := historyRepo(t)
	gitIn(t, dir, "config", "log.showRoot", "false")
	r := openRepo(t, dir)
	got, err := r.CommitFiles(context.Background(), ids["init"], nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got[ids["init"]]) == 0 {
		t.Fatalf("root commit files = %q, want its paths", got)
	}
}

func TestParseCommitFiles_MalformedHeaderIsAnError(t *testing.T) {
	if _, err := parseCommitFiles([]byte(commitMark + "not-a-sha\x00\na.go\x00")); err == nil {
		t.Fatal("a malformed header parsed")
	}
}

func TestHeadCommitAndDefaultTip(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	ctx := context.Background()
	head, err := r.HeadCommit(ctx)
	if err != nil || head != strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD")) {
		t.Fatalf("HeadCommit = %q, %v", head, err)
	}
	if tip, err := r.DefaultTip(ctx); err != nil || tip != "refs/heads/main" {
		t.Fatalf("DefaultTip = %q, %v", tip, err)
	}

	unborn := t.TempDir()
	gitIn(t, unborn, "init", "-q", "-b", "main")
	u := openRepo(t, unborn)
	if head, err := u.HeadCommit(ctx); err != nil || head != "" {
		t.Fatalf("unborn HeadCommit = %q, %v", head, err)
	}
	if tip, err := u.DefaultTip(ctx); err != nil || tip != "" {
		t.Fatalf("unborn DefaultTip = %q, %v", tip, err)
	}
}
