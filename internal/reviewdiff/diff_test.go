package reviewdiff

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiff_StatusesHunksAndOddPaths(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "gone.txt", "bye\n")
	writeFile(t, dir, "old name.txt", "same content here\nline2\nline3\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "more")
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))

	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	os.Remove(filepath.Join(dir, "gone.txt"))
	if err := os.Rename(filepath.Join(dir, "old name.txt"), filepath.Join(dir, "new name.txt")); err != nil {
		t.Fatal(err)
	}
	odd := "dir name/файл \"q\".go"
	writeFile(t, dir, odd, "package x\n")
	writeFile(t, dir, "img.bin", "\x00\x01\x02")

	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]File{}
	for _, f := range d.Files {
		byPath[f.Path] = f
	}
	if f := byPath["a.go"]; f.Status != "modified" || f.Additions != 1 || f.Deletions != 1 || len(f.Hunks) != 1 {
		t.Fatalf("a.go = %+v", f)
	}
	if f := byPath["gone.txt"]; f.Status != "deleted" {
		t.Fatalf("gone.txt = %+v", f)
	}
	if f := byPath["new name.txt"]; f.Status != "renamed" || f.OldPath != "old name.txt" {
		t.Fatalf("rename = %+v", f)
	}
	if f := byPath[odd]; f.Status != "added" || len(f.Hunks) != 1 || f.Hunks[0].Lines[0] != "+package x" {
		t.Fatalf("odd path = %+v (all: %v)", f, d.Files)
	}
	if f := byPath["img.bin"]; !f.Binary || len(f.Hunks) != 0 {
		t.Fatalf("binary = %+v", f)
	}
	h := byPath["a.go"].Hunks[0]
	if h.ID == "" || h.NewStart == 0 {
		t.Fatalf("hunk = %+v", h)
	}
	again, _ := r.Diff(context.Background(), base, tree)
	for _, f := range again.Files {
		if f.Path == "a.go" && f.Hunks[0].ID != h.ID {
			t.Fatal("hunk id not stable")
		}
	}
}

func TestDiff_CollapsedAndCaps(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "go.sum", "x v1 h1:abc\n")
	writeFile(t, dir, "big.txt", strings.Repeat("line\n", MaxFileChangedLines+1))
	tree, _ := r.Snapshot(context.Background())
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, f := range d.Files {
		switch f.Path {
		case "go.sum":
			seen++
			if f.CollapsedReason != "lockfile" {
				t.Fatalf("go.sum = %+v", f)
			}
		case "big.txt":
			seen++
			if f.CollapsedReason != "too_large" || len(f.Hunks) != 0 || f.Additions != MaxFileChangedLines+1 {
				t.Fatalf("big.txt = %+v", f)
			}
		}
	}
	if seen != 2 {
		t.Fatalf("expected go.sum and big.txt, got %+v", d.Files)
	}
}

func TestFile_BothSides(t *testing.T) {
	dir := newRepo(t)
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "a.go", "package a\n// changed\n")
	tree, _ := r.Snapshot(context.Background())
	old, err := r.File(context.Background(), base, "a.go")
	if err != nil || !old.Exists || !strings.Contains(old.Text, "return 1") {
		t.Fatalf("old = %+v, %v", old, err)
	}
	cur, _ := r.File(context.Background(), tree, "a.go")
	if !strings.Contains(cur.Text, "// changed") {
		t.Fatalf("new = %+v", cur)
	}
	missing, err := r.File(context.Background(), base, "nope.go")
	if err != nil || missing.Exists {
		t.Fatalf("missing = %+v, %v", missing, err)
	}
}

func TestDiff_TypeChangeToSymlink(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "f", "plain\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "f")
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	if err := os.Remove(filepath.Join(dir, "f")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("a.go", filepath.Join(dir, "f")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, f := range d.Files {
		switch f.Path {
		case "f":
			n++
			if f.Status != "modified" || len(f.Hunks) == 0 {
				t.Fatalf("f = %+v", f)
			}
		case "a.go":
			if len(f.Hunks) != 1 {
				t.Fatalf("a.go = %+v", f)
			}
		}
	}
	if n != 1 {
		t.Fatalf("f listed %d times: %+v", n, d.Files)
	}
}

func TestSplitSections_LineOverMaxIsAnError(t *testing.T) {
	patch := []byte("diff --git a/x b/x\n@@ -0,0 +1 @@\n+" + strings.Repeat("y", 5000) + "\n")
	if _, err := splitSections(patch, 1024); err == nil {
		t.Fatal("over-long line silently truncated the patch")
	}
	if _, err := splitSections(patch, 1<<20); err != nil {
		t.Fatal(err)
	}
}

// TestDiff_SuppressBlankEmptyKeepsBlankContext: with diff.suppressBlankEmpty
// git prints a blank context line bare; it stays a context line.
func TestDiff_SuppressBlankEmptyKeepsBlankContext(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "config", "diff.suppressBlankEmpty", "true")
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Files) != 1 || len(d.Files[0].Hunks) != 1 {
		t.Fatalf("diff = %+v", d.Files)
	}
	h := d.Files[0].Hunks[0]
	want := []string{" package a", " ", "-func A() int { return 1 }", "+func A() int { return 2 }"}
	if strings.Join(h.Lines, "|") != strings.Join(want, "|") {
		t.Fatalf("lines = %q, want %q", h.Lines, want)
	}
	if h.OldLines != 3 || h.NewLines != 3 {
		t.Fatalf("hunk = %+v", h)
	}
}

// TestDiff_NewBlobAndMode: each file carries its new side's blob id and
// mode; a deleted file carries neither.
func TestDiff_NewBlobAndMode(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "gone.txt", "bye\n")
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "more")
	r := openRepo(t, dir)
	base := strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD"))
	writeFile(t, dir, "a.go", "package a // new\n")
	writeFile(t, dir, "img.bin", "\x00\x01")
	if err := os.Remove(filepath.Join(dir, "gone.txt")); err != nil {
		t.Fatal(err)
	}
	tree, _ := r.Snapshot(context.Background())
	d, err := r.Diff(context.Background(), base, tree)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range d.Files {
		switch f.Path {
		case "a.go", "img.bin":
			want := strings.TrimSpace(gitIn(t, dir, "rev-parse", tree+":"+f.Path))
			if f.NewBlob != want || f.NewMode != "100644" {
				t.Fatalf("%s = blob %q mode %q, want %q 100644", f.Path, f.NewBlob, f.NewMode, want)
			}
		case "gone.txt":
			if f.NewBlob != "" || f.NewMode != "" {
				t.Fatalf("deleted file = %+v", f)
			}
		}
	}
	if len(d.Files) != 3 {
		t.Fatalf("files = %+v", d.Files)
	}
}
