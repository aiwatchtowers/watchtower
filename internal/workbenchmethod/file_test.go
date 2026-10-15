package workbenchmethod

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func writeWorkflow(t *testing.T, folder, content string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(folder, FileRel), []byte(content), 0o644))
}

func TestReadFile_NoFileIsAbsent(t *testing.T) {
	assert.Equal(t, File{}, ReadFile(t.TempDir()))
	folder := t.TempDir()
	require.NoError(t, os.Mkdir(filepath.Join(folder, ".watchtower"), 0o755))
	assert.Equal(t, File{}, ReadFile(folder), "an empty .watchtower is no file")
}

func TestReadFile_FrontmatterAndBody(t *testing.T) {
	folder := t.TempDir()
	writeWorkflow(t, folder, "---\npreset: none          # watchtower-flow | none\nask_guard: soft\nfinish_check: off\n---\n\n"+
		"Plans live in docs/plans/.\r\nNever open a PR without a Jira issue.\n")
	f := ReadFile(folder)
	require.NoError(t, f.Err)
	assert.True(t, f.Present)
	assert.Equal(t, "none", f.Preset)
	assert.Equal(t, "soft", f.AskGuard)
	assert.Equal(t, "off", f.FinishCheck)
	assert.Equal(t, "Plans live in docs/plans/.\nNever open a PR without a Jira issue.", f.Body)
	assert.Equal(t, utf8.RuneCountInString(f.Body), f.BodyChars)
	assert.False(t, f.Truncated)
}

func TestParse_NoFrontmatterIsAllBody(t *testing.T) {
	f, err := Parse([]byte("Just rules.\n"), false)
	require.NoError(t, err)
	assert.Equal(t, "Just rules.", f.Body)
	assert.Empty(t, f.Preset+f.AskGuard+f.FinishCheck)
}

func TestParse_BOMAndCommentOnlyFrontmatter(t *testing.T) {
	f, err := Parse([]byte("\ufeff---\n# preset: none\n---\nRules."), false)
	require.NoError(t, err)
	assert.Empty(t, f.Preset)
	assert.Equal(t, "Rules.", f.Body)
}

func TestParse_UnquotedOnAndOffAreValues(t *testing.T) {
	f, err := Parse([]byte("---\nfinish_check: on\nask_guard: off\n---\n"), false)
	require.NoError(t, err)
	assert.Equal(t, "on", f.FinishCheck)
	assert.Equal(t, "off", f.AskGuard)
}

// Spec §5: duplicate keys, unknown keys and bad values refuse the whole file.
func TestParse_RefusesWholeFile(t *testing.T) {
	for name, content := range map[string]string{
		"unknown key":   "---\nmode: strict\n---\nbody",
		"duplicate key": "---\nask_guard: soft\nask_guard: off\n---\nbody",
		"bad value":     "---\nask_guard: loose\n---\nbody",
		"bool value":    "---\nfinish_check: true\n---\nbody",
		"list value":    "---\npreset: [none]\n---\nbody",
		"not a mapping": "---\n- preset\n---\nbody",
		"unclosed":      "---\npreset: none\nbody",
		"broken yaml":   "---\npreset: \"none\n---\nbody",
		"invalid utf-8": "---\npreset: none\n---\n\xff\xfe",
	} {
		_, err := Parse([]byte(content), false)
		assert.Error(t, err, name)
	}
}

// A refused file never weakens a check: none of its keys, and no body, apply.
func TestReadFile_RefusedFileKeepsNoKeys(t *testing.T) {
	folder := t.TempDir()
	writeWorkflow(t, folder, "---\nask_guard: off\nmode: x\n---\nbody")
	f := ReadFile(folder)
	require.Error(t, f.Err)
	assert.True(t, f.Present)
	assert.Empty(t, f.AskGuard)
	assert.Empty(t, f.Body)
}

func TestReadFile_SymlinksAndSpecialFilesAreNotRead(t *testing.T) {
	outsideDir := t.TempDir()
	outside := filepath.Join(outsideDir, "workflow.md")
	require.NoError(t, os.WriteFile(outside, []byte("---\nask_guard: off\n---\n"), 0o644))

	fileLink := t.TempDir()
	require.NoError(t, os.Mkdir(filepath.Join(fileLink, ".watchtower"), 0o755))
	require.NoError(t, os.Symlink(outside, filepath.Join(fileLink, FileRel)))

	dirLink := t.TempDir()
	require.NoError(t, os.Symlink(outsideDir, filepath.Join(dirLink, ".watchtower")))

	fifo := t.TempDir()
	require.NoError(t, os.Mkdir(filepath.Join(fifo, ".watchtower"), 0o755))
	require.NoError(t, syscall.Mkfifo(filepath.Join(fifo, FileRel), 0o644))

	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, FileRel), 0o755))

	for name, folder := range map[string]string{"file link": fileLink, "directory link": dirLink, "fifo": fifo, "directory": dir} {
		f := ReadFile(folder) // a FIFO must not block: lstat refuses it before any open
		assert.True(t, f.Present, name)
		assert.Error(t, f.Err, name)
		assert.Empty(t, f.AskGuard, name)
	}
}

func TestReadFile_CutsAt64KiBOnARuneBoundary(t *testing.T) {
	folder := t.TempDir()
	head := "---\nask_guard: soft\n---\nx" // an odd length, so the cut splits a two-byte rune
	writeWorkflow(t, folder, head+strings.Repeat("я", MaxFileBytes))
	f := ReadFile(folder)
	require.NoError(t, f.Err)
	assert.True(t, f.Truncated)
	assert.Equal(t, "soft", f.AskGuard)
	assert.True(t, utf8.ValidString(f.Body))
	assert.LessOrEqual(t, len(head)+len(f.Body)-1, MaxFileBytes)
	assert.Equal(t, utf8.RuneCountInString(f.Body), f.BodyChars)
}

func TestCreateTemplate_WritesOnceAndParsesClean(t *testing.T) {
	folder := t.TempDir()
	created, err := CreateTemplate(folder)
	require.NoError(t, err)
	assert.True(t, created)
	f := ReadFile(folder)
	require.NoError(t, f.Err, "the template must parse: every key is commented out")
	assert.Empty(t, f.Preset+f.AskGuard+f.FinishCheck)
	assert.NotEmpty(t, f.Body)

	require.NoError(t, os.WriteFile(filepath.Join(folder, FileRel), []byte("mine"), 0o644))
	created, err = CreateTemplate(folder)
	require.NoError(t, err)
	assert.False(t, created)
	got, err := os.ReadFile(filepath.Join(folder, FileRel))
	require.NoError(t, err)
	assert.Equal(t, "mine", string(got), "never overwrites")
}

func TestCreateTemplate_NeverWritesThroughALink(t *testing.T) {
	outside := t.TempDir()
	folder := t.TempDir()
	require.NoError(t, os.Symlink(outside, filepath.Join(folder, ".watchtower")))
	_, err := CreateTemplate(folder)
	require.Error(t, err)
	_, statErr := os.Stat(filepath.Join(outside, "workflow.md"))
	assert.True(t, os.IsNotExist(statErr))

	dangling := t.TempDir()
	require.NoError(t, os.Mkdir(filepath.Join(dangling, ".watchtower"), 0o755))
	target := filepath.Join(outside, "elsewhere.md")
	require.NoError(t, os.Symlink(target, filepath.Join(dangling, FileRel)))
	created, err := CreateTemplate(dangling)
	require.NoError(t, err)
	assert.False(t, created)
	_, statErr = os.Stat(target)
	assert.True(t, os.IsNotExist(statErr), "never writes through a link")
}
