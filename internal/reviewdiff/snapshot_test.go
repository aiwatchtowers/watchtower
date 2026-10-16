package reviewdiff

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
)

func TestReview01_SnapshotWritesNoRefNoIndex(t *testing.T) {
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

// gitDirFiles lists every file under .git except objects/, sorted.
func gitDirFiles(t *testing.T, dir string) []string {
	t.Helper()
	root := filepath.Join(dir, ".git")
	var files []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if d.IsDir() {
			if rel == "objects" {
				return filepath.SkipDir
			}
			return nil
		}
		files = append(files, rel)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	return files
}

func TestReview01_SnapshotWritesNoSharedIndex(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, dir string)
	}{
		{"split index configured", func(t *testing.T, dir string) {
			gitIn(t, dir, "config", "core.splitIndex", "true")
		}},
		{"owner index already split, expire set", func(t *testing.T, dir string) {
			gitIn(t, dir, "config", "core.splitIndex", "true")
			gitIn(t, dir, "config", "splitIndex.sharedIndexExpire", "now")
			gitIn(t, dir, "update-index", "--split-index")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := newRepo(t)
			tc.setup(t, dir)
			writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
			writeFile(t, dir, "new/b.go", "package new\n")
			filesBefore := gitDirFiles(t, dir)
			indexBefore, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))

			tree, err := openRepo(t, dir).Snapshot(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if ls := gitIn(t, dir, "ls-tree", "-r", "--name-only", tree); !strings.Contains(ls, "new/b.go") {
				t.Fatalf("snapshot tree misses the untracked file:\n%s", ls)
			}
			if after := gitDirFiles(t, dir); !slices.Equal(filesBefore, after) {
				t.Fatalf("snapshot changed files in .git:\nbefore %v\nafter  %v", filesBefore, after)
			}
			indexAfter, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))
			if !bytes.Equal(indexBefore, indexAfter) {
				t.Fatal("snapshot wrote the owner's index")
			}
		})
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
	if ok, err := r.TreeExists(context.Background(), tree); err != nil || !ok {
		t.Fatalf("fresh snapshot reported missing (%v)", err)
	}
	if ok, err := r.TreeExists(context.Background(), strings.Repeat("1", 40)); err != nil || ok {
		t.Fatalf("unknown sha reported present (%v)", err)
	}
}

// TestSnapshot_OwnerIndexSeedMatchesReadTree: seeding the temporary index
// from a copy of the owner's index gives the read-tree HEAD path's tree, with
// staged, unstaged, untracked and deleted changes alike, and leaves the
// owner's index bytes alone; a split index falls back to read-tree HEAD.
func TestSnapshot_OwnerIndexSeedMatchesReadTree(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "staged.go", "package a // staged\n")
	gitIn(t, dir, "add", "staged.go")
	writeFile(t, dir, "staged.go", "package a // staged, then edited\n")
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 3 }\n")
	writeFile(t, dir, "untracked.txt", "u\n")
	writeFile(t, dir, ".gitignore", "*.log\n")
	writeFile(t, dir, "skip.log", "ignored\n")
	indexBefore, _ := os.ReadFile(filepath.Join(dir, ".git", "index"))

	r := openRepo(t, dir)
	seeded, err := r.snapshot(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := r.snapshot(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if seeded != plain {
		t.Fatalf("owner-index seed tree %s != read-tree tree %s", seeded, plain)
	}
	if ls := gitIn(t, dir, "ls-tree", "-r", "--name-only", seeded); strings.Contains(ls, "skip.log") {
		t.Fatalf("an ignored file is in the snapshot:\n%s", ls)
	}
	if indexAfter, _ := os.ReadFile(filepath.Join(dir, ".git", "index")); !bytes.Equal(indexBefore, indexAfter) {
		t.Fatal("seeding from the owner's index wrote it")
	}

	gitIn(t, dir, "config", "core.splitIndex", "true")
	gitIn(t, dir, "update-index", "--split-index")
	if r.copyOwnerIndex(context.Background(), filepath.Join(t.TempDir(), "index")) {
		t.Fatal("a split index was copied")
	}
	split, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if split != plain {
		t.Fatalf("split-index snapshot %s != %s", split, plain)
	}
}

// TestSnapshot_DoneContextIsAnError: a cancelled call never reads as "no
// commit", "no default branch", "not in the tree" or "tree pruned".
func TestSnapshot_DoneContextIsAnError(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := r.Snapshot(ctx); err == nil {
		t.Fatal("Snapshot under a cancelled context succeeded")
	}
	if b, err := r.Base(ctx); err == nil {
		t.Fatalf("Base under a cancelled context = %+v, no error", b)
	}
	if s, err := r.File(ctx, tree, "a.go"); err == nil {
		t.Fatalf("File under a cancelled context = %+v, no error", s)
	}
	if _, err := r.TreeExists(ctx, tree); err == nil {
		t.Fatal("TreeExists under a cancelled context answered")
	}
	if _, err := r.hasHead(ctx); err == nil {
		t.Fatal("hasHead under a cancelled context answered")
	}
}
