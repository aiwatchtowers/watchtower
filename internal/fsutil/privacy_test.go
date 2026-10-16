package fsutil

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestPrivacyProtected_Table(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	protected := []string{
		filepath.Join(home, "Documents", "acme"),
		filepath.Join(home, "documents", "acme"), // APFS ignores case
		filepath.Join(home, "DESKTOP"),
		filepath.Join(home, "Downloads", "x"),
		filepath.Join(home, "Library", "CloudStorage", "x", "y"),
		filepath.Join(home, "Library", "Mobile Documents", "a"),
		"/Volumes/USB/acme",
		"/volumes/x",
		"/Volumes",
	}
	for _, folder := range protected {
		assert.True(t, PrivacyProtected(folder), folder)
	}
	for _, folder := range []string{
		filepath.Join(home, "Code", "acme"),
		filepath.Join(home, "DocumentsArchive"),
		filepath.Join(home, "Documentsx"),
		"/VolumesX/a",
		"/tmp/x",
	} {
		assert.False(t, PrivacyProtected(folder), folder)
	}
}

func TestHasPathPrefix(t *testing.T) {
	assert.True(t, HasPathPrefix("/a/B", "/a/b"))
	assert.True(t, HasPathPrefix("/a/b/c", "/A/B"))
	assert.False(t, HasPathPrefix("/a/bc", "/a/b"))
	assert.False(t, HasPathPrefix("/a", "/a/b"))
}
