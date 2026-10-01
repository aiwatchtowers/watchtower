package projectfiles

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const pngMagic = "\x89PNG\r\n\x1a\n"

func writeSource(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	return p
}

func TestIngest_StoresAPrivateContentNamedCopyOnce(t *testing.T) {
	ws := t.TempDir()
	s := New(ws)
	src := writeSource(t, "Screenshot 1.png", pngMagic+"pixels")

	img, err := s.Ingest(7, src)
	require.NoError(t, err)
	assert.Equal(t, "Screenshot 1.png", img.FileName)
	assert.Equal(t, "image/png", img.MIME)
	assert.Equal(t, int64(len(pngMagic)+6), img.Size)
	assert.Equal(t, filepath.Join(ws, "project_files", "7", img.SHA256+".png"), img.Path)

	info, err := os.Stat(img.Path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	for _, dir := range []string{filepath.Join(ws, "project_files"), s.Dir(7)} {
		info, err := os.Stat(dir)
		require.NoError(t, err)
		assert.Equal(t, os.FileMode(0o700), info.Mode().Perm(), dir)
	}

	assert.True(t, img.Created)
	again, err := s.Ingest(7, writeSource(t, "copy.png", pngMagic+"pixels"))
	require.NoError(t, err)
	assert.Equal(t, img.Path, again.Path, "the same content is stored once per project")
	assert.False(t, again.Created, "a reused copy is not this call's to discard")
	entries, err := os.ReadDir(s.Dir(7))
	require.NoError(t, err)
	assert.Len(t, entries, 1, "no temp file is left behind")
}

func TestIngest_DecidesTypeByContent(t *testing.T) {
	s := New(t.TempDir())
	for name, content := range map[string]string{
		"a.jpg":  "\xff\xd8\xff\xe0jpeg",
		"a.gif":  "GIF89a....",
		"a.webp": "RIFF\x00\x00\x00\x00WEBPVP8 ",
	} {
		img, err := s.Ingest(1, writeSource(t, name, content))
		require.NoError(t, err, name)
		assert.Equal(t, filepath.Ext(name), filepath.Ext(img.Path), name)
	}
}

func TestIngest_RefusesWhatIsNotASmallImageFile(t *testing.T) {
	s := New(t.TempDir())
	dir := t.TempDir()
	target := writeSource(t, "real.png", pngMagic+"x")
	link := filepath.Join(dir, "link.png")
	require.NoError(t, os.Symlink(target, link))
	big := writeSource(t, "big.png", pngMagic+strings.Repeat("x", int(MaxImageBytes)))
	fifo := filepath.Join(dir, "pipe.png")
	require.NoError(t, syscall.Mkfifo(fifo, 0o600))

	for name, src := range map[string]string{
		"relative":          "shot.png",
		"missing":           filepath.Join(dir, "missing.png"),
		"symlink":           link,
		"directory":         dir,
		"text named as png": writeSource(t, "fake.png", "just text"),
		"svg":               writeSource(t, "a.svg", `<svg xmlns="http://www.w3.org/2000/svg"></svg>`),
		"empty":             writeSource(t, "empty.png", ""),
		"over the cap":      big,
		"fifo (never hangs)": fifo,
	} {
		_, err := s.Ingest(1, src)
		var rej *RejectError
		assert.True(t, errors.As(err, &rej), "%s: want a RejectError, got %v", name, err)
	}
	_, err := os.Stat(s.Dir(1))
	assert.True(t, os.IsNotExist(err), "a refused file creates nothing")
}

func TestDiscard_RemovesOnlyUnreferencedCopiesInsideTheStore(t *testing.T) {
	ws := t.TempDir()
	s := New(ws)
	kept, err := s.Ingest(1, writeSource(t, "k.png", pngMagic+"keep"))
	require.NoError(t, err)
	gone, err := s.Ingest(1, writeSource(t, "g.png", pngMagic+"gone"))
	require.NoError(t, err)
	outside := writeSource(t, "owner.png", pngMagic+"owner")
	nested := filepath.Join(ws, "project_files", "1", "sub", "x.png")

	require.NoError(t, s.Discard([]string{kept.Path, gone.Path, outside, nested, gone.Path + ".missing"},
		map[string]bool{kept.Path: true}))
	_, err = os.Stat(gone.Path)
	assert.True(t, os.IsNotExist(err))
	for _, p := range []string{kept.Path, outside} {
		_, err := os.Stat(p)
		assert.NoError(t, err, p)
	}
}

func TestRemoveProject_DeletesOnlyThatProjectsDirectory(t *testing.T) {
	s := New(t.TempDir())
	_, err := s.Ingest(1, writeSource(t, "a.png", pngMagic+"a"))
	require.NoError(t, err)
	b, err := s.Ingest(2, writeSource(t, "b.png", pngMagic+"b"))
	require.NoError(t, err)

	require.NoError(t, s.RemoveProject(1))
	require.NoError(t, s.RemoveProject(1), "a missing directory is a no-op")
	_, err = os.Stat(s.Dir(1))
	assert.True(t, os.IsNotExist(err))
	_, err = os.Stat(b.Path)
	assert.NoError(t, err)
}
