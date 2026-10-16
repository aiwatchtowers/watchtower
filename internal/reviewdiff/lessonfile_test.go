package reviewdiff

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func lessonFolder(t *testing.T, content *string) (folder, file string) {
	t.Helper()
	folder = t.TempDir()
	file = filepath.Join(folder, ".watchtower", "review.md")
	if content != nil {
		require.NoError(t, os.MkdirAll(filepath.Dir(file), 0o755))
		require.NoError(t, os.WriteFile(file, []byte(*content), 0o644))
	}
	return folder, file
}

func ptr(s string) *string { return &s }

func TestAppendLessonRule_InsertsUnderTheHeading(t *testing.T) {
	cases := []struct {
		name             string
		before           *string
		lens, text, want string
	}{
		{"existing section", ptr("## Tests\n- a\n\n## Docs\n- b\n"), "Tests", "new", "## Tests\n- a\n- new\n\n## Docs\n- b\n"},
		{"lens id matches heading", ptr("## Tests\n- a\n\n## Docs\n- b\n"), "docs", "new", "## Tests\n- a\n\n## Docs\n- b\n- new\n"},
		{"no file", nil, "House rules", "new", "## House rules\n- new\n"},
		{"new section, no final newline", ptr("## Tests\n- a"), "Docs", "new", "## Tests\n- a\n\n## Docs\n- new\n"},
		{"empty file", ptr(""), "Docs", "new", "## Docs\n- new\n"},
		{"duplicate", ptr("## Tests\n- Does it?\n"), "Tests", "Does it?", "## Tests\n- Does it?\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			folder, file := lessonFolder(t, c.before)
			require.NoError(t, AppendLessonRule(folder, c.lens, c.text))
			got, err := os.ReadFile(file)
			require.NoError(t, err)
			assert.Equal(t, c.want, string(got))
			if c.before != nil {
				info, err := os.Stat(file)
				require.NoError(t, err)
				assert.Equal(t, fs.FileMode(0o644), info.Mode().Perm())
			}
			left, _ := filepath.Glob(filepath.Join(folder, ".watchtower", ".review-*"))
			assert.Empty(t, left)
		})
	}
}

func TestAppendLessonRule_RefusesUnsafe(t *testing.T) {
	t.Run("symlinked .watchtower", func(t *testing.T) {
		folder := t.TempDir()
		linked := t.TempDir()
		require.NoError(t, os.Symlink(linked, filepath.Join(folder, ".watchtower")))
		assert.Error(t, AppendLessonRule(folder, "Tests", "x"))
		entries, _ := os.ReadDir(linked)
		assert.Empty(t, entries)
	})
	t.Run("symlinked review.md", func(t *testing.T) {
		folder, file := lessonFolder(t, ptr(""))
		outside := filepath.Join(t.TempDir(), "outside.md")
		require.NoError(t, os.WriteFile(outside, []byte("keep\n"), 0o644))
		require.NoError(t, os.Remove(file))
		require.NoError(t, os.Symlink(outside, file))
		assert.Error(t, AppendLessonRule(folder, "Tests", "x"))
		got, _ := os.ReadFile(outside)
		assert.Equal(t, "keep\n", string(got))
	})
	t.Run("fifo", func(t *testing.T) {
		folder, file := lessonFolder(t, ptr(""))
		require.NoError(t, os.Remove(file))
		require.NoError(t, syscall.Mkfifo(file, 0o644))
		done := make(chan error, 1)
		go func() { done <- AppendLessonRule(folder, "Tests", "x") }()
		select {
		case err := <-done:
			assert.Error(t, err)
		case <-time.After(2 * time.Second):
			t.Fatal("AppendLessonRule blocked on a FIFO")
		}
	})
	t.Run("over 64 KB", func(t *testing.T) {
		big := "## Tests\n- " + strings.Repeat("a", MaxLensFileBytes-20) + "\n"
		folder, file := lessonFolder(t, &big)
		assert.Error(t, AppendLessonRule(folder, "Tests", strings.Repeat("b", 100)))
		got, _ := os.ReadFile(file)
		assert.Equal(t, big, string(got))
	})
	t.Run(".watchtower is a file", func(t *testing.T) {
		folder := t.TempDir()
		require.NoError(t, os.WriteFile(filepath.Join(folder, ".watchtower"), []byte("x"), 0o644))
		assert.Error(t, AppendLessonRule(folder, "Tests", "x"))
	})
}

// snapshot: every path under root (git internals included) with its bytes.
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	require.NoError(t, filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if d.IsDir() {
			out[rel+"/"] = ""
			return nil
		}
		b, err := os.ReadFile(p)
		out[rel] = string(b)
		return err
	}))
	return out
}

func TestReview01_LessonAcceptWritesOnlyReviewMD(t *testing.T) {
	repo := t.TempDir()
	run := func(args ...string) {
		c := exec.Command("git", args...)
		c.Dir = repo
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
		out, err := c.CombinedOutput()
		require.NoError(t, err, string(out))
	}
	run("init", "-q")
	require.NoError(t, os.WriteFile(filepath.Join(repo, "main.go"), []byte("package main\n"), 0o644))
	run("add", "main.go")
	run("commit", "-q", "-m", "init")
	require.NoError(t, os.WriteFile(filepath.Join(repo, "dirty.txt"), []byte("untracked\n"), 0o644))

	before := snapshot(t, repo)
	require.NoError(t, AppendLessonRule(repo, "House rules", "Does every handler check the owner?"))
	after := snapshot(t, repo)

	added := map[string]bool{}
	for k, v := range after {
		old, existed := before[k]
		if !existed {
			added[k] = true
		} else {
			assert.Equal(t, old, v, "%s changed", k)
		}
	}
	for k := range before {
		_, ok := after[k]
		assert.True(t, ok, "%s vanished", k)
	}
	assert.Equal(t, map[string]bool{".watchtower/": true, ".watchtower/review.md": true}, added)
}
