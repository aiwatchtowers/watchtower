package reviewdiff

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// roundDiff snapshots dir's work tree and diffs HEAD → the snapshot.
func roundDiff(t *testing.T, r *Repo, dir string) Diff {
	t.Helper()
	tree, err := r.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d, err := r.Diff(context.Background(), strings.TrimSpace(gitIn(t, dir, "rev-parse", "HEAD")), tree)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func fileOf(t *testing.T, d Diff, path string) File {
	t.Helper()
	for _, f := range d.Files {
		if f.Path == path {
			return f
		}
	}
	t.Fatalf("%s not in the diff: %+v", path, d.Files)
	return File{}
}

func readFile(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func commitFile(t *testing.T, dir, name, content string) {
	t.Helper()
	writeFile(t, dir, name, content)
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "add "+name)
}

func numbered(n int, edit map[int]string) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		if s, ok := edit[i]; ok {
			b.WriteString(s + "\n")
			continue
		}
		fmt.Fprintf(&b, "line %d\n", i)
	}
	return b.String()
}

func refusal(t *testing.T, err error) string {
	t.Helper()
	var u UndoRefused
	if !errors.As(err, &u) {
		t.Fatalf("want UndoRefused, got %v", err)
	}
	return u.Msg
}

func TestRevertHunk_ModifiedKeepsTheOtherHunk(t *testing.T) {
	dir := newRepo(t)
	commitFile(t, dir, "dir name/n.txt", numbered(40, nil))
	writeFile(t, dir, "dir name/n.txt", numbered(40, map[int]string{3: "edit one", 35: "edit two"}))
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), "dir name/n.txt")
	if len(f.Hunks) != 2 {
		t.Fatalf("hunks = %+v", f.Hunks)
	}
	rev, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if rev.Path != f.Path || rev.HunkID != f.Hunks[0].ID || rev.Header != f.Hunks[0].Header || !strings.Contains(rev.Patch, "+edit one") {
		t.Fatalf("reverted = %+v", rev)
	}
	if got, want := readFile(t, dir, "dir name/n.txt"), numbered(40, map[int]string{35: "edit two"}); got != want {
		t.Fatalf("file = %q, want %q", got, want)
	}
}

func TestRevertHunk_AddedFileIsRemoved(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "new.txt", "fresh\n")
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), "new.txt")
	if _, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "new.txt")); !os.IsNotExist(err) {
		t.Fatalf("new.txt still there: %v", err)
	}
}

func TestRevertHunk_DeletedFileIsRestored(t *testing.T) {
	dir := newRepo(t)
	commitFile(t, dir, "run.sh", "#!/bin/sh\necho hi\n")
	if err := os.Chmod(filepath.Join(dir, "run.sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "add", "-A")
	gitIn(t, dir, "commit", "-q", "-m", "exec")
	if err := os.Remove(filepath.Join(dir, "run.sh")); err != nil {
		t.Fatal(err)
	}
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), "run.sh")
	if f.Status != "deleted" || f.OldMode != "100755" {
		t.Fatalf("file = %+v", f)
	}
	if _, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, "run.sh"); got != "#!/bin/sh\necho hi\n" {
		t.Fatalf("content = %q", got)
	}
	info, err := os.Lstat(filepath.Join(dir, "run.sh"))
	if err != nil || info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("mode not restored: %v %v", info, err)
	}
}

func TestRevertHunk_NoNewlineAtEOF(t *testing.T) {
	dir := newRepo(t)
	commitFile(t, dir, "e.txt", "one\ntwo")
	writeFile(t, dir, "e.txt", "one\nTWO")
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), "e.txt")
	h := f.Hunks[0]
	if !slices.Contains(h.Lines, `\ No newline at end of file`) {
		t.Fatalf("lines = %q", h.Lines)
	}
	if _, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, h.ID); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, "e.txt"); got != "one\ntwo" {
		t.Fatalf("content = %q", got)
	}
}

func TestRevertHunk_RefusesUnsupported(t *testing.T) {
	h := Hunk{ID: "0123456789abcdef", Header: "@@ -1 +1 @@", Lines: []string{"-a", "+b"}}
	r := openRepo(t, newRepo(t))
	for _, tc := range []struct {
		name string
		d    Diff
		want string
	}{
		{"renamed", Diff{Files: []File{{Path: "b", OldPath: "a", Status: "renamed", Hunks: []Hunk{h}}}}, "renamed"},
		{"binary", Diff{Files: []File{{Path: "b", Status: "modified", Binary: true, Hunks: []Hunk{h}}}}, "binary"},
		{"symlink", Diff{Files: []File{{Path: "b", Status: "modified", NewMode: "120000", OldMode: "120000", Hunks: []Hunk{h}}}}, "symlink"},
		{"to symlink", Diff{Files: []File{{Path: "b", Status: "modified", NewMode: "120000", OldMode: "100644", Hunks: []Hunk{h}}}}, "symlink"},
		{"submodule", Diff{Files: []File{{Path: "b", Status: "modified", NewMode: "160000", OldMode: "160000", Hunks: []Hunk{h}}}}, "submodule"},
		{"too large", Diff{Files: []File{{Path: "b", Status: "modified", CollapsedReason: "too_large", Hunks: []Hunk{h}}}}, "too large"},
		{"truncated", Diff{Truncated: true, Files: []File{{Path: "b", Status: "modified"}}}, "truncated"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := r.RevertHunk(context.Background(), tc.d, h.ID)
			if got, want := refusal(t, err), "undo is not available for a "+tc.want+" file"; got != want {
				t.Fatalf("refusal = %q, want %q", got, want)
			}
		})
	}
	_, err := r.RevertHunk(context.Background(), Diff{}, h.ID)
	if got := refusal(t, err); got != "hunk 0123456789abcdef is not in this round's diff" {
		t.Fatalf("missing hunk refusal = %q", got)
	}
}

func TestReview02_RefusedWhenFileChanged(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), "a.go")
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 3 }\n")
	_, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID)
	if got := refusal(t, err); got != "the file changed since this round's snapshot — refresh first" {
		t.Fatalf("refusal = %q", got)
	}
	if got := readFile(t, dir, "a.go"); got != "package a\n\nfunc A() int { return 3 }\n" {
		t.Fatalf("file touched: %q", got)
	}
	// A deleted file that came back is changed too.
	commitFile(t, dir, "d.txt", "d\n")
	if err := os.Remove(filepath.Join(dir, "d.txt")); err != nil {
		t.Fatal(err)
	}
	gone := fileOf(t, roundDiff(t, r, dir), "d.txt")
	writeFile(t, dir, "d.txt", "back\n")
	_, err = r.RevertHunk(context.Background(), Diff{Files: []File{gone}}, gone.Hunks[0].ID)
	if got := refusal(t, err); got != "the file changed since this round's snapshot — refresh first" {
		t.Fatalf("deleted refusal = %q", got)
	}
}

// recorder wraps the real runner, keeping every argv; fail (optional) makes
// a call fail without running it.
func recorder(argvs *[][]string, fail func(args []string) bool) Runner {
	return func(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
		*argvs = append(*argvs, slices.Clone(args))
		if fail != nil && fail(args) {
			return nil, errors.New("git apply: exit 1: patch does not apply")
		}
		return execRunner(ctx, dir, env, name, args...)
	}
}

func applies(argvs [][]string) (checks, writes int) {
	for _, a := range argvs {
		if len(a) == 0 || a[0] != "apply" {
			continue
		}
		if slices.Contains(a, "--check") {
			checks++
		} else {
			writes++
		}
	}
	return checks, writes
}

func TestReview02_CheckFailureAppliesNothing(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	gitBin(t)
	var argvs [][]string
	r, err := Open(dir, recorder(&argvs, func(a []string) bool { return a[0] == "apply" && slices.Contains(a, "--check") }))
	if err != nil {
		t.Fatal(err)
	}
	f := fileOf(t, roundDiff(t, r, dir), "a.go")
	_, err = r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID)
	if got := refusal(t, err); got != "this hunk no longer applies to the file" {
		t.Fatalf("refusal = %q", got)
	}
	if checks, writes := applies(argvs); checks != 1 || writes != 0 {
		t.Fatalf("apply calls: %d checks, %d writes", checks, writes)
	}
	if got := readFile(t, dir, "a.go"); got != "package a\n\nfunc A() int { return 2 }\n" {
		t.Fatalf("file touched: %q", got)
	}
}

func refsOf(t *testing.T, dir string) string {
	t.Helper()
	return gitIn(t, dir, "for-each-ref", "--format=%(refname) %(objectname)") + gitIn(t, dir, "rev-parse", "HEAD")
}

func TestReview01_UndoWritesOnlyTheHunksFile(t *testing.T) {
	dir := newRepo(t)
	writeFile(t, dir, "a.go", "package a\n\nfunc A() int { return 2 }\n")
	writeFile(t, dir, "other.txt", "untracked\n")
	gitBin(t)
	var argvs [][]string
	r, err := Open(dir, recorder(&argvs, nil))
	if err != nil {
		t.Fatal(err)
	}
	f := fileOf(t, roundDiff(t, r, dir), "a.go")
	// status refreshes the owner's index itself: read it after that, compare before the next one.
	before := gitIn(t, dir, "status", "--porcelain")
	index, err := os.ReadFile(filepath.Join(dir, ".git", "index"))
	if err != nil {
		t.Fatal(err)
	}
	refs := refsOf(t, dir)
	if _, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, ".git", "index")); err != nil || !bytes.Equal(got, index) {
		t.Fatalf("the owner's index changed (%v)", err)
	}
	if refsOf(t, dir) != refs {
		t.Fatal("a ref changed")
	}
	after := gitIn(t, dir, "status", "--porcelain")
	if before != " M a.go\n?? other.txt\n" || after != "?? other.txt\n" {
		t.Fatalf("status before %q, after %q", before, after)
	}
	for _, a := range argvs {
		if slices.Contains(a, "--index") || slices.Contains(a, "--cached") {
			t.Fatalf("argv %q touches the index", a)
		}
	}
	if checks, writes := applies(argvs); checks != 1 || writes != 1 {
		t.Fatalf("apply calls: %d checks, %d writes", checks, writes)
	}
}

func TestHunkPatch_Shapes(t *testing.T) {
	h := Hunk{Header: "@@ -1 +1 @@ ctx", Lines: []string{"-a", "+b", `\ No newline at end of file`}}
	if got, want := HunkPatch(File{Path: "x y.txt", Status: "modified"}, h),
		"diff --git a/x y.txt b/x y.txt\n--- a/x y.txt\t\n+++ b/x y.txt\t\n@@ -1 +1 @@ ctx\n-a\n+b\n\\ No newline at end of file\n"; got != want {
		t.Fatalf("modified:\n%q\nwant\n%q", got, want)
	}
	if got, want := HunkPatch(File{Path: "n", Status: "added", NewMode: "100644"}, Hunk{Header: "@@ -0,0 +1 @@", Lines: []string{"+n"}}),
		"diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+n\n"; got != want {
		t.Fatalf("added:\n%q\nwant\n%q", got, want)
	}
	if got, want := HunkPatch(File{Path: "d", Status: "deleted", OldMode: "100755"}, Hunk{Header: "@@ -1 +0,0 @@", Lines: []string{"-d"}}),
		"diff --git a/d b/d\ndeleted file mode 100755\n--- a/d\n+++ /dev/null\n@@ -1 +0,0 @@\n-d\n"; got != want {
		t.Fatalf("deleted:\n%q\nwant\n%q", got, want)
	}
	if got := HunkPatch(File{Path: "q\"é", Status: "modified"}, h); !strings.HasPrefix(got, `diff --git "a/q\"\303\251" "b/q\"\303\251"`+"\n"+`--- "a/q\"\303\251"`) {
		t.Fatalf("quoted: %q", got)
	}
}

func TestRevertHunk_OddPathRoundTrips(t *testing.T) {
	dir := newRepo(t)
	odd := "dir name/файл \"q\".txt"
	commitFile(t, dir, odd, "x\n")
	writeFile(t, dir, odd, "y\n")
	r := openRepo(t, dir)
	f := fileOf(t, roundDiff(t, r, dir), odd)
	if _, err := r.RevertHunk(context.Background(), Diff{Files: []File{f}}, f.Hunks[0].ID); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, odd); got != "x\n" {
		t.Fatalf("content = %q", got)
	}
}

// A workbench bound to a subfolder: the round's paths are top-relative, so
// Undo runs from the repository top — inside the subfolder and outside it.
func TestRevertHunk_FromASubfolderWorksAtTheTop(t *testing.T) {
	dir := newRepo(t)
	commitFile(t, dir, "sub/in.txt", "in\n")
	commitFile(t, dir, "out.txt", "out\n")
	commitFile(t, dir, "gone.txt", "gone\n")
	writeFile(t, dir, "sub/in.txt", "IN\n")
	writeFile(t, dir, "out.txt", "OUT\n")
	if err := os.Remove(filepath.Join(dir, "gone.txt")); err != nil {
		t.Fatal(err)
	}
	d := roundDiff(t, openRepo(t, dir), dir) // the round's diff, from the top
	sub, err := Open(filepath.Join(dir, "sub"), nil)
	if err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]string{"sub/in.txt": "in\n", "out.txt": "out\n", "gone.txt": "gone\n"} {
		f := fileOf(t, d, path)
		if _, err := sub.RevertHunk(context.Background(), d, f.Hunks[0].ID); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if got := readFile(t, dir, path); got != want {
			t.Fatalf("%s = %q, want %q", path, got, want)
		}
	}
}

// A parent swapped for a symlink never lets apply reach outside the repository.
func TestRevertHunk_RefusesASymlinkedParent(t *testing.T) {
	dir := newRepo(t)
	commitFile(t, dir, "p/f.txt", "keep\n")
	commitFile(t, dir, "q/g.txt", "g\n")
	if err := os.Remove(filepath.Join(dir, "p", "f.txt")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, dir, "q/g.txt", "G\n")
	r := openRepo(t, dir)
	d := roundDiff(t, r, dir)
	outside := t.TempDir()
	writeFile(t, outside, "g.txt", "G\n")
	for _, p := range []string{"p", "q"} {
		if err := os.RemoveAll(filepath.Join(dir, p)); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(outside, filepath.Join(dir, p)); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range []string{"p/f.txt", "q/g.txt"} {
		f := fileOf(t, d, path)
		_, err := r.RevertHunk(context.Background(), d, f.Hunks[0].ID)
		if got := refusal(t, err); got != "undo is not available for a symlink file" {
			t.Fatalf("%s refusal = %q", path, got)
		}
	}
	if got := readFile(t, outside, "g.txt"); got != "G\n" {
		t.Fatalf("outside file = %q", got)
	}
	if _, err := os.Lstat(filepath.Join(outside, "f.txt")); !os.IsNotExist(err) {
		t.Fatalf("a file was written outside: %v", err)
	}
}
