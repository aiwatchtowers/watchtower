package workbenchdocs

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/gitbin"
)

// gitBin is the located git, or the test is skipped. The environment keeps
// the owner's own git configuration out of the test repositories.
func gitBin(t *testing.T) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git is not available")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	return bin
}

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	c := exec.Command(gitBin(t), args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	require.NoError(t, err, "git %s: %s", strings.Join(args, " "), out)
}

func writeAt(t *testing.T, folder, rel, text string) {
	t.Helper()
	p := filepath.Join(folder, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
	require.NoError(t, os.WriteFile(p, []byte(text), 0o600))
}

func fileRelPaths(files []File) []string {
	out := make([]string, 0, len(files))
	for _, f := range files {
		out = append(out, f.RelPath)
	}
	return out
}

// newRepoFolder is a git repository holding a tracked .md, an untracked
// .txt that no rule ignores, an ignored .md, an ignored worktree's file and
// a file that is no text document.
func newRepoFolder(t *testing.T) string {
	t.Helper()
	gitBin(t)
	folder := t.TempDir()
	gitIn(t, folder, "init", "-q")
	writeAt(t, folder, ".gitignore", "build/\n.claude/worktrees/\n")
	writeAt(t, folder, "docs/spec.md", "# Spec\n")
	writeAt(t, folder, "main.go", "package main\n")
	gitIn(t, folder, "add", ".gitignore", "docs/spec.md", "main.go")
	writeAt(t, folder, "notes.txt", "untracked notes\n")
	writeAt(t, folder, "build/out.md", "ignored\n")
	writeAt(t, folder, ".claude/worktrees/x/a.md", "another worktree's file\n")
	return folder
}

func TestListTextFiles_GitListsTrackedAndUntrackedButNotIgnored(t *testing.T) {
	folder := newRepoFolder(t)
	files, err := ListTextFiles(context.Background(), folder)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"docs/spec.md", "notes.txt"}, fileRelPaths(files))
}

// The workbench's own worktrees are skipped even when no ignore rule says
// so — the Go twin of the Files tree's hidden names.
func TestListTextFiles_GitSkipsTheHiddenNamesTooEvenWhenNotIgnored(t *testing.T) {
	folder := newRepoFolder(t)
	writeAt(t, folder, ".gitignore", "build/\n")
	writeAt(t, folder, "node_modules/pkg/README.md", "a dependency\n")
	writeAt(t, folder, "docs/.DS_Store", "x")
	files, err := ListTextFiles(context.Background(), folder)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"docs/spec.md", "notes.txt"}, fileRelPaths(files))
}

// A tracked file deleted from the working tree is still in the index (git
// ls-files --cached), but it is no file of the folder any more.
func TestListTextFiles_GitDropsATrackedFileGoneFromDisk(t *testing.T) {
	folder := newRepoFolder(t)
	require.NoError(t, os.Remove(filepath.Join(folder, "docs/spec.md")))
	files, err := ListTextFiles(context.Background(), folder)
	require.NoError(t, err)
	assert.Equal(t, []string{"notes.txt"}, fileRelPaths(files))
}

// A git run that fails is an error, never an empty listing: the caller
// would otherwise wipe the folder's index entries.
func TestListTextFiles_FailingGitIsAnError(t *testing.T) {
	folder := newRepoFolder(t)
	fake := filepath.Join(t.TempDir(), "git")
	require.NoError(t, os.WriteFile(fake, []byte("#!/bin/sh\necho broken >&2\nexit 1\n"), 0o755))
	files, err := Lister{Locate: func() (string, bool) { return fake, true }}.List(context.Background(), folder)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "broken")
	assert.Nil(t, files)
}

// Without git (no Command Line Tools) a repository folder is walked like a
// plain one, rather than never indexed.
func TestListTextFiles_NoGitWalksTheRepository(t *testing.T) {
	folder := newRepoFolder(t)
	files, err := Lister{Locate: func() (string, bool) { return "", false }}.List(context.Background(), folder)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"docs/spec.md", "notes.txt", "build/out.md"}, fileRelPaths(files),
		"the walk skips .git and .claude/worktrees, but knows no ignore rules")
}

// Outside git the walk skips the hidden names (.git, node_modules,
// .claude/worktrees, the installed skills, …), keeps .md/.markdown/.txt in any case, and never
// follows a symlink — not to a directory outside the folder, not to a file.
func TestListTextFiles_WalkOutsideGit(t *testing.T) {
	folder := t.TempDir()
	require.False(t, gitbin.InsideRepository(folder), "the temp dir must not sit in a repository")
	writeAt(t, folder, "README.md", "readme")
	writeAt(t, folder, "docs/Guide.MARKDOWN", "guide")
	writeAt(t, folder, "docs/notes.txt", "notes")
	writeAt(t, folder, "docs/data.json", "{}")
	writeAt(t, folder, "vendor/lib/.git/HEAD.md", "x") // a nested checkout
	writeAt(t, folder, "node_modules/pkg/README.md", "x")
	writeAt(t, folder, ".build/x.md", "x")
	writeAt(t, folder, ".claude/worktrees/x/a.md", "x")
	writeAt(t, folder, ".claude/skills/s.md", "the owner's own skill")
	writeAt(t, folder, ".claude/skills/watchtower-workbench/SKILL.md", "the installed skill")
	writeAt(t, folder, ".claude/skills/watchtower-project/SKILL.md", "the pre-rename installed skill")
	outside := t.TempDir()
	writeAt(t, outside, "secret.md", "private")
	require.NoError(t, os.Symlink(outside, filepath.Join(folder, "linked")))
	require.NoError(t, os.Symlink(filepath.Join(outside, "secret.md"), filepath.Join(folder, "secret.md")))

	files, err := ListTextFiles(context.Background(), folder)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"README.md", "docs/Guide.MARKDOWN", "docs/notes.txt", ".claude/skills/s.md"}, fileRelPaths(files))
}

func TestListTextFiles_MissingFolderIsAnError(t *testing.T) {
	_, err := ListTextFiles(context.Background(), filepath.Join(t.TempDir(), "gone"))
	require.Error(t, err)
}

// Past MaxTextFiles the newest files are kept and the cut is logged with
// the count.
func TestListTextFiles_CapKeepsTheNewestAndLogsTheCut(t *testing.T) {
	folder := t.TempDir()
	base := time.Now().Add(-time.Hour)
	for i := range MaxTextFiles + 1 {
		rel := fmt.Sprintf("n%04d.md", i)
		writeAt(t, folder, rel, "x")
		at := base.Add(time.Duration(i) * time.Second)
		require.NoError(t, os.Chtimes(filepath.Join(folder, rel), at, at))
	}
	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	files, err := ListTextFiles(context.Background(), folder)
	require.NoError(t, err)
	require.Len(t, files, MaxTextFiles)
	assert.Equal(t, fmt.Sprintf("n%04d.md", MaxTextFiles), files[0].RelPath, "newest first")
	assert.NotContains(t, fileRelPaths(files), "n0000.md", "the oldest is cut")
	assert.Contains(t, logged.String(), "2001 text files")
	assert.Contains(t, logged.String(), "2000 newest")
}
