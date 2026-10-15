package reviewdiff

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSnapshot_IncludesUntrackedAndLeavesIndexAndRefsAlone(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	writeFile(t, dir, "new/b.go", "package new\n")
	indexBefore, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))
	refsBefore := gitIn(t, dir, "for-each-ref")

	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ls := gitIn(t, dir, "ls-tree", "-r", "--name-only", tree)
	if !strings.Contains(ls, "new/b.go") || !strings.Contains(ls, "a.go") {
		t.Fatalf("snapshot tree misses files:\n%s", ls)
	}
	indexAfter, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))
	if !bytes.Equal(indexBefore, indexAfter) {
		t.Fatal("snapshot wrote the owner's index")
	}
	if refsAfter := gitIn(t, dir, "for-each-ref"); refsAfter != refsBefore {
		t.Fatalf("snapshot moved refs:\n%s\nvs\n%s", refsBefore, refsAfter)
	}
	if st := gitIn(t, dir, "status", "--porcelain"); !strings.Contains(st, "?? new/") {
		t.Fatalf("untracked file got staged in the owner's index:\n%s", st)
	}
}

func TestSnapshot_NoCommitYet(t *testing.T) {
	dir := t.TempDir()
	gitIn(t, dir, "init", "-q", "-b", "main")
	writeFile(t, dir, "x.txt", "x\n")
	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	base, err := r.Base(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if base.SHA != EmptyTree || base.Label != "" {
		t.Fatalf("base = %+v, want the empty tree", base)
	}
	d, err := r.Diff(context.Background(), base.SHA, tree)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Files) != 1 || d.Files[0].Status != "added" || d.Files[0].Path != "x.txt" {
		t.Fatalf("diff = %+v", d.Files)
	}
}

func TestBase_MergeBaseWithDefaultBranch(t *testing.T) {
	dir := newRepo(t)
	mainSHA := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	gitIn(t, dir, "switch", "-q", "-c", "feature")
	writeFile(t, dir, "f.go", "package a\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "f")
	b, err := openRepo(t, dir).Base(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if b.SHA != mainSHA || b.Label != "main" {
		t.Fatalf("base = %+v, want %s main", b, mainSHA)
	}
}

func TestTreeExists(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	tree, _ := r.Snapshot(context.Background())
	if !r.TreeExists(context.Background(), tree) {
		t.Fatal("fresh snapshot reported missing")
	}
	if r.TreeExists(context.Background(), strings.Repeat("1", 40)) {
		t.Fatal("unknown sha reported present")
	}
}
