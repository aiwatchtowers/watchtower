package codewalk

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"

	"watchtower/internal/gitbin"
)

// write creates rel under root with data, making its directories.
func write(t *testing.T, root, rel string, data []byte) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func symlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

// gitInit makes dir a repository and returns a git runner for it; it skips
// the test when this machine has no git outside the macOS shim.
func gitInit(t *testing.T, dir string) func(args ...string) {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("no git binary")
	}
	git := func(args ...string) {
		c := exec.Command(bin, args...)
		c.Dir = dir
		c.Env = append(gitEnv(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	git("init", "-q")
	return git
}

// list collects every file the walk yields, failing on an error.
func list(t *testing.T, seq func(yield func(File, error) bool)) []string {
	t.Helper()
	var out []string
	for f, err := range seq {
		if err != nil {
			t.Fatalf("walk error: %v", err)
		}
		out = append(out, f.Rel)
	}
	slices.Sort(out)
	return out
}

func noGit() (string, bool) { return "", false }

func TestFiles_GitRepoListsTrackedAndUntrackedNotIgnored(t *testing.T) {
	repo := t.TempDir()
	git := gitInit(t, repo)
	write(t, repo, ".gitignore", []byte("*.log\nbuild/\n"))
	write(t, repo, "top.go", []byte("package top\n"))
	write(t, repo, "app/main.go", []byte("package main\n"))
	write(t, repo, "app/new.go", []byte("package main\n"))
	write(t, repo, "app/debug.log", []byte("ignored\n"))
	write(t, repo, "build/out.go", []byte("package out\n"))
	write(t, repo, "node_modules/kept.js", []byte("// git decides, not the hidden list\n"))
	git("add", "top.go", "app/main.go")

	got := list(t, Files(context.Background(), repo))
	want := []string{".gitignore", "app/main.go", "app/new.go", "node_modules/kept.js", "top.go"}
	if !slices.Equal(got, want) {
		t.Fatalf("Files(repo) = %v, want %v", got, want)
	}

	// A workbench folder below the repository root: paths relative to it.
	got = list(t, Files(context.Background(), filepath.Join(repo, "app")))
	want = []string{"main.go", "new.go"}
	if !slices.Equal(got, want) {
		t.Fatalf("Files(repo/app) = %v, want %v", got, want)
	}
}

func TestFiles_NoRepoSkipsHiddenNames(t *testing.T) {
	root := t.TempDir()
	if gitbin.InsideRepository(root) {
		t.Skip("the temp dir is inside a repository")
	}
	for _, name := range hiddenFixture(t) {
		write(t, root, filepath.Join(name, "inside.go"), []byte("package x\n"))
		write(t, root, filepath.Join("src", name), []byte("a hidden name as a file\n"))
	}
	write(t, root, "src/a.go", []byte("package src\n"))
	write(t, root, "readme.md", []byte("# hi\n"))

	got := list(t, Files(context.Background(), root))
	want := []string{"readme.md", "src/a.go"}
	if !slices.Equal(got, want) {
		t.Fatalf("Files(no repo) = %v, want %v", got, want)
	}
}

// A repository whose git cannot be found falls back to the directory walk:
// .git and the hidden names are skipped, and .gitignore no longer applies.
func TestFiles_GitMissingFallsBackToTheWalk(t *testing.T) {
	repo := t.TempDir()
	write(t, repo, ".git/HEAD", []byte("ref: refs/heads/main\n"))
	write(t, repo, ".gitignore", []byte("*.log\n"))
	write(t, repo, "main.go", []byte("package main\n"))
	write(t, repo, "debug.log", []byte("listed without git\n"))
	write(t, repo, ".build/x.o", []byte("obj\n"))
	if !gitbin.InsideRepository(repo) {
		t.Fatal("fixture should look like a repository")
	}

	got := list(t, files(context.Background(), repo, noGit))
	want := []string{".gitignore", "debug.log", "main.go"}
	if !slices.Equal(got, want) {
		t.Fatalf("files(git missing) = %v, want %v", got, want)
	}
}

// A repository whose git fails (here: a .git file pointing nowhere) also
// falls back instead of yielding nothing.
func TestFiles_GitFailureFallsBackToTheWalk(t *testing.T) {
	if _, ok := gitbin.Locate(); !ok {
		t.Skip("no git binary")
	}
	repo := t.TempDir()
	write(t, repo, ".git", []byte("gitdir: /nonexistent/worktree\n"))
	write(t, repo, "main.go", []byte("package main\n"))

	got := list(t, Files(context.Background(), repo))
	if !slices.Equal(got, []string{"main.go"}) {
		t.Fatalf("Files(broken repo) = %v, want [main.go]", got)
	}
}

func hiddenFixture(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile("testdata/hidden_names.json")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	if err := json.Unmarshal(data, &names); err != nil {
		t.Fatal(err)
	}
	return names
}

// The Go list is a copy of CodeFileTree.hiddenNames; the Swift suite reads
// the same fixture, so the two cannot drift apart silently.
func TestHiddenNames_MatchTheSharedFixture(t *testing.T) {
	names := hiddenFixture(t)
	if len(names) != len(hiddenNames) {
		t.Fatalf("fixture has %d names, Go has %d", len(names), len(hiddenNames))
	}
	for _, n := range names {
		if !hiddenNames[n] {
			t.Errorf("hidden name %q is in the fixture but not in Go", n)
		}
	}
}

// skipFixture lays out every case the walk must skip, plus the files next
// to them it must still list.
func skipFixture(t *testing.T, root string) {
	t.Helper()
	outside := t.TempDir()
	write(t, outside, "secret.go", []byte("package secret\n"))
	write(t, root, "real.go", []byte("package real\n"))
	write(t, root, "big.txt", bytes.Repeat([]byte("a"), MaxSearchBytes+1))
	write(t, root, "index-too-big.txt", bytes.Repeat([]byte("a"), MaxIndexBytes+1))
	binary := bytes.Repeat([]byte("a"), 100)
	binary[50] = 0
	write(t, root, "blob.bin", binary)
	late := bytes.Repeat([]byte("a"), headBytes+10)
	late[headBytes+5] = 0
	write(t, root, "late-nul.txt", late)
	write(t, root, "dir/sub.go", []byte("package dir\n"))
	symlink(t, filepath.Join(outside, "secret.go"), filepath.Join(root, "leak.go"))
	symlink(t, "real.go", filepath.Join(root, "alias.go"))
	symlink(t, "dir", filepath.Join(root, "dirlink"))
}

func TestFiles_Skips(t *testing.T) {
	want := []string{"dir/sub.go", "index-too-big.txt", "late-nul.txt", "real.go"}
	t.Run("walk", func(t *testing.T) {
		root := t.TempDir()
		skipFixture(t, root)
		if got := list(t, files(context.Background(), root, noGit)); !slices.Equal(got, want) {
			t.Fatalf("walk = %v, want %v", got, want)
		}
	})
	t.Run("git", func(t *testing.T) {
		root := t.TempDir()
		git := gitInit(t, root)
		skipFixture(t, root)
		git("add", "-A")
		if got := list(t, Files(context.Background(), root)); !slices.Equal(got, want) {
			t.Fatalf("git = %v, want %v", got, want)
		}
	})
}

// A symlink inside the folder to a file inside it whose target is not
// listed itself (here: hidden) is listed under the link's own name, once.
func TestFiles_SymlinkToAnUnlistedInsideFileIsListedOnce(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".build/gen.go", []byte("package gen\n"))
	symlink(t, ".build/gen.go", filepath.Join(root, "gen.go"))
	symlink(t, ".build/gen.go", filepath.Join(root, "gen2.go"))
	got := list(t, files(context.Background(), root, noGit))
	if !slices.Equal(got, []string{"gen.go"}) {
		t.Fatalf("walk = %v, want [gen.go]", got)
	}
}

func TestFiles_ReportsSize(t *testing.T) {
	root := t.TempDir()
	write(t, root, "a.go", []byte("package a\n"))
	for f, err := range files(context.Background(), root, noGit) {
		if err != nil {
			t.Fatal(err)
		}
		if f.Rel != "a.go" || f.Size != 10 {
			t.Fatalf("got %+v, want a.go of 10 bytes", f)
		}
	}
}

func TestFiles_UnreadableRootIsAnError(t *testing.T) {
	var got error
	for _, err := range files(context.Background(), filepath.Join(t.TempDir(), "missing"), noGit) {
		got = err
	}
	if !errors.Is(got, fs.ErrNotExist) {
		t.Fatalf("err = %v, want fs.ErrNotExist", got)
	}
}

func TestFiles_CancelledContextStops(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{"a.go", "b.go", "c.go"} {
		write(t, root, n, []byte("package x\n"))
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var got error
	n := 0
	for _, err := range files(ctx, root, noGit) {
		if err != nil {
			got = err
			break
		}
		n++
	}
	if !errors.Is(got, context.Canceled) || n != 0 {
		t.Fatalf("yielded %d files then %v, want 0 then context.Canceled", n, got)
	}
}

func TestLookup(t *testing.T) {
	root := t.TempDir()
	skipFixture(t, root)
	cases := []struct {
		rel     string
		wantErr error
	}{
		{"real.go", nil},
		{"alias.go", nil},
		{"index-too-big.txt", nil},
		{"gone.go", fs.ErrNotExist},
		{"dir", ErrSkipped},
		{"leak.go", ErrSkipped},
		{"blob.bin", ErrSkipped},
		{"big.txt", ErrSkipped},
		{"../escape.go", ErrSkipped},
		{"/etc/hosts", ErrSkipped},
	}
	for _, tc := range cases {
		f, err := Lookup(root, tc.rel)
		if !errors.Is(err, tc.wantErr) {
			t.Errorf("Lookup(%q) err = %v, want %v", tc.rel, err, tc.wantErr)
			continue
		}
		if err == nil && (f.Rel != tc.rel || f.Size == 0) {
			t.Errorf("Lookup(%q) = %+v", tc.rel, f)
		}
	}
}

// A directory symlink is resolved too: a file reached through a link to a
// directory outside the folder is skipped, and one reached through a link
// to an inside directory is the same file, listed once.
func TestFiles_DirectoryLinksInThePath(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	write(t, outside, "secret.go", []byte("package secret\n"))
	write(t, root, "dir/sub.go", []byte("package dir\n"))
	symlink(t, outside, filepath.Join(root, "dirout"))
	symlink(t, "dir", filepath.Join(root, "dirin"))

	if _, err := Lookup(root, "dirout/secret.go"); !errors.Is(err, ErrSkipped) {
		t.Errorf("Lookup(dirout/secret.go) err = %v, want ErrSkipped", err)
	}
	if f, err := Lookup(root, "dirin/sub.go"); err != nil || f.Rel != "dirin/sub.go" {
		t.Errorf("Lookup(dirin/sub.go) = %+v, %v; want the inside file", f, err)
	}
	// Candidates naming paths through both links (as a git list of a
	// repository with such entries would) yield the inside file once.
	w, err := newWalker(root)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	w.list(context.Background(), slices.Values([]string{"dirin/sub.go", "dirout/secret.go", "dir/sub.go"}), func(f File, err error) bool {
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, f.Rel)
		return true
	})
	if !slices.Equal(got, []string{"dir/sub.go"}) {
		t.Fatalf("listed %v, want [dir/sub.go]", got)
	}
	if got := list(t, files(context.Background(), root, noGit)); !slices.Equal(got, []string{"dir/sub.go"}) {
		t.Fatalf("walk = %v, want [dir/sub.go]", got)
	}
}
