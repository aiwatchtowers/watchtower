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
