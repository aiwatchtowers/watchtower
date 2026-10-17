package chat

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestPublishDir(t *testing.T) (workDir string, d *PublishDir) {
	t.Helper()
	workDir = filepath.Join(t.TempDir(), "cwd")
	d, err := NewPublishDir(workDir, 42)
	require.NoError(t, err)
	return workDir, d
}

// Every escape attempt is refused; a path inside (new or existing) is fine.
func TestPublishDir_Check(t *testing.T) {
	workDir, d := newTestPublishDir(t)
	dir := d.Path()
	outside := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("x"), 0o600))
	require.NoError(t, os.Mkdir(filepath.Join(dir, "sub"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "sub", "page.html"), []byte("x"), 0o600))
	require.NoError(t, os.Symlink(outside, filepath.Join(dir, "linkdir")))
	require.NoError(t, os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(dir, "link.html")))
	require.NoError(t, os.Link(filepath.Join(outside, "secret.txt"), filepath.Join(dir, "hard.html")))
	other, err := NewPublishDir(workDir, 43)
	require.NoError(t, err)

	cases := []struct {
		name string
		path string
		want error // nil = allowed
	}{
		{"new file inside", filepath.Join(dir, "deck.html"), nil},
		{"nested new path", filepath.Join(dir, "a", "b", "deck.html"), nil},
		{"existing file inside", filepath.Join(dir, "sub", "page.html"), nil},
		{"the dir itself", dir, nil},
		{"trailing slash and dot", dir + "/./sub/", nil},
		{"relative under the work dir", filepath.Join("publish", "42", "a.html"), nil},
		{"relative bare name resolves to the work dir", "a.html", ErrOutsidePublishDir},
		{"relative dot-slash", "./publish/42/a.html", nil},
		{"dot-dot out", dir + "/../43/x.html", ErrOutsidePublishDir},
		{"dot-dot that cleans back inside", dir + "/sub/../x.html", ErrOutsidePublishDir},
		{"relative dot-dot", "../x", ErrOutsidePublishDir},
		{"absolute outside", filepath.Join(outside, "secret.txt"), ErrOutsidePublishDir},
		{"documents", "/Users/someone/Documents/x.html", ErrOutsidePublishDir},
		{"tilde", "~/Documents/x.html", ErrOutsidePublishDir},
		{"tilde user", "~root/x", ErrOutsidePublishDir},
		{"work dir itself", workDir, ErrOutsidePublishDir},
		{"publish parent", filepath.Dir(dir), ErrOutsidePublishDir},
		{"sibling conversation", filepath.Join(other.Path(), "x.html"), ErrOutsidePublishDir},
		{"sibling sharing the id prefix", dir + "0/x.html", ErrOutsidePublishDir},
		{"case variant of the dir", strings.ToUpper(dir) + "/x.html", ErrOutsidePublishDir},
		{"empty", "", ErrOutsidePublishDir},
		{"nul byte", filepath.Join(dir, "a\x00b"), ErrOutsidePublishDir},
		{"symlink dir inside pointing out", filepath.Join(dir, "linkdir", "secret.txt"), ErrUnsafePublishPath},
		{"symlink file inside pointing out", filepath.Join(dir, "link.html"), ErrUnsafePublishPath},
		{"case variant of a symlink inside", filepath.Join(dir, "LINKDIR", "secret.txt"), nil}, // see below
		{"hard link to an outside file", filepath.Join(dir, "hard.html"), ErrUnsafePublishPath},
		{"file used as a folder", filepath.Join(dir, "sub", "page.html", "x"), ErrUnsafePublishPath},
	}
	caseInsensitive := pathExists(filepath.Join(dir, "SUB"))
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			want := tc.want
			if tc.name == "case variant of a symlink inside" && caseInsensitive {
				want = ErrUnsafePublishPath // APFS default: LINKDIR is the planted link
			}
			err := d.Check(tc.path)
			if want == nil {
				assert.NoError(t, err)
				return
			}
			assert.ErrorIs(t, err, want)
		})
	}
}

func pathExists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// The CLI's cwd is the resolved spelling of the work dir (macOS: /var is a
// symlink to /private/var); a path under that spelling is the same folder.
func TestPublishDir_CheckAcceptsTheResolvedSpelling(t *testing.T) {
	root := t.TempDir()
	realRoot := filepath.Join(root, "real")
	require.NoError(t, os.Mkdir(realRoot, 0o700))
	alias := filepath.Join(root, "alias")
	require.NoError(t, os.Symlink(realRoot, alias))
	d, err := NewPublishDir(filepath.Join(alias, "cwd"), 7)
	require.NoError(t, err)

	resolved, err := filepath.EvalSymlinks(d.Path())
	require.NoError(t, err)
	require.NotEqual(t, d.Path(), resolved)
	assert.NoError(t, d.Check(filepath.Join(resolved, "deck.html")))
	assert.NoError(t, d.Check(filepath.Join(d.Path(), "deck.html")))
	assert.ErrorIs(t, d.Check(filepath.Join(realRoot, "cwd", "deck.html")), ErrOutsidePublishDir)
}

// An outside path is decided from its text: Check never stats it (no TCC
// prompt), so even an unreadable parent yields the outside error, and the
// only paths ever handed to lstat are inside the publish dir.
func TestPublishDir_NeverTouchesOutsidePaths(t *testing.T) {
	_, d := newTestPublishDir(t)
	var seen []string
	d.lstat = func(p string) (os.FileInfo, error) {
		seen = append(seen, p)
		return os.Lstat(p)
	}
	locked := filepath.Join(t.TempDir(), "locked")
	require.NoError(t, os.Mkdir(locked, 0o700))
	require.NoError(t, os.Chmod(locked, 0o000))
	t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })

	for _, p := range []string{
		filepath.Join(locked, "x.html"),
		"/Users/someone/Documents/x.html",
		"/Users/someone/Desktop/x.html",
		"~/Documents/x.html",
		d.Path() + "/../../x",
		"a.html",
	} {
		err := d.Check(p)
		require.ErrorIs(t, err, ErrOutsidePublishDir, p)
		assert.NotContains(t, err.Error(), "permission denied", p)
	}
	assert.Empty(t, seen, "an outside path must never reach a syscall")

	require.NoError(t, d.Check(filepath.Join(d.Path(), "a", "b.html")))
	require.NotEmpty(t, seen)
	for _, p := range seen {
		assert.True(t, p == d.Path() || strings.HasPrefix(p, d.Path()+"/"), "stat'ed %s", p)
	}
}

// The dir and its parents are 0700; a planted symlink at any level is
// refused before anything is created through it.
func TestPublishDir_CreatedPrivate(t *testing.T) {
	workDir, d := newTestPublishDir(t)
	assert.Equal(t, filepath.Join(workDir, "publish", "42"), d.Path())
	for _, p := range []string{workDir, filepath.Join(workDir, "publish"), d.Path()} {
		info, err := os.Lstat(p)
		require.NoError(t, err)
		assert.True(t, info.IsDir(), p)
		assert.Equal(t, os.FileMode(0o700), info.Mode().Perm(), p)
	}

	t.Run("symlink at the conversation level", func(t *testing.T) {
		target := t.TempDir()
		workDir := filepath.Join(t.TempDir(), "cwd")
		require.NoError(t, os.MkdirAll(filepath.Join(workDir, "publish"), 0o700))
		require.NoError(t, os.Symlink(target, filepath.Join(workDir, "publish", "42")))
		_, err := NewPublishDir(workDir, 42)
		var we *WorkDirError
		require.ErrorAs(t, err, &we)
	})
	t.Run("symlink at the publish level is never followed", func(t *testing.T) {
		target := t.TempDir()
		workDir := filepath.Join(t.TempDir(), "cwd")
		require.NoError(t, os.Mkdir(workDir, 0o700))
		require.NoError(t, os.Symlink(target, filepath.Join(workDir, "publish")))
		_, err := NewPublishDir(workDir, 42)
		var we *WorkDirError
		require.ErrorAs(t, err, &we)
		entries, err := os.ReadDir(target)
		require.NoError(t, err)
		assert.Empty(t, entries, "nothing may be created through the planted link")
	})
	t.Run("a file at the conversation level", func(t *testing.T) {
		workDir := filepath.Join(t.TempDir(), "cwd")
		require.NoError(t, os.MkdirAll(filepath.Join(workDir, "publish"), 0o700))
		require.NoError(t, os.WriteFile(filepath.Join(workDir, "publish", "42"), nil, 0o600))
		_, err := NewPublishDir(workDir, 42)
		var we *WorkDirError
		require.ErrorAs(t, err, &we)
	})
	t.Run("an existing private dir is reused", func(t *testing.T) {
		require.NoError(t, os.WriteFile(filepath.Join(d.Path(), "keep.html"), nil, 0o600))
		again, err := NewPublishDir(workDir, 42)
		require.NoError(t, err)
		assert.FileExists(t, filepath.Join(again.Path(), "keep.html"))
	})
	t.Run("bad arguments", func(t *testing.T) {
		_, err := NewPublishDir("relative/cwd", 42)
		require.Error(t, err)
		_, err = NewPublishDir(workDir, 0)
		require.Error(t, err)
		_, err = NewPublishDir(workDir, -1)
		require.Error(t, err)
	})
}

// A publish dir swapped after creation (removed, or replaced by a symlink to
// a folder outside) is refused rather than written through.
func TestPublishDir_CheckRefusesAReplacedDir(t *testing.T) {
	_, d := newTestPublishDir(t)
	require.NoError(t, os.Remove(d.Path()))
	require.NoError(t, os.Symlink(t.TempDir(), d.Path()))
	assert.ErrorIs(t, d.Check(filepath.Join(d.Path(), "x.html")), ErrUnsafePublishPath)

	require.NoError(t, os.Remove(d.Path()))
	require.NoError(t, os.Mkdir(d.Path(), 0o700))
	assert.ErrorIs(t, d.Check(filepath.Join(d.Path(), "x.html")), ErrUnsafePublishPath, "a new dir is not the one created")
}

// Removing one conversation's dir leaves another's intact, and a symlink
// inside is removed, not followed.
func TestPublishDir_RemoveOnlyOwnConversation(t *testing.T) {
	workDir, d := newTestPublishDir(t)
	other, err := NewPublishDir(workDir, 43)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(other.Path(), "keep.html"), nil, 0o600))
	outside := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(outside, "keep.txt"), nil, 0o600))
	require.NoError(t, os.Symlink(outside, filepath.Join(d.Path(), "link")))
	require.NoError(t, os.WriteFile(filepath.Join(d.Path(), "deck.html"), nil, 0o600))

	require.NoError(t, d.Remove())
	assert.NoDirExists(t, d.Path())
	assert.FileExists(t, filepath.Join(other.Path(), "keep.html"))
	assert.FileExists(t, filepath.Join(outside, "keep.txt"))
	require.NoError(t, d.Remove(), "idempotent")
}
