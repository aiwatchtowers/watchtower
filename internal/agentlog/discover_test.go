package agentlog

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSlug(t *testing.T) {
	assert.Equal(t, "-Users-a-my-app--claude-worktrees-x", Slug("/Users/a/my app/.claude/worktrees/x"))
}

func TestCandidateDirs_PrefixOnlyAndNoSymlinks(t *testing.T) {
	proj := t.TempDir()
	for _, d := range []string{"-w-app", "-w-app-sub", "-w-app--claude-worktrees-x", "-w-apple", "-other"} {
		require.NoError(t, os.Mkdir(filepath.Join(proj, d), 0o755))
	}
	require.NoError(t, os.Symlink(filepath.Join(proj, "-other"), filepath.Join(proj, "-w-app-link")))
	got, err := CandidateDirs(proj, []string{"/w/app"})
	require.NoError(t, err)
	var names []string
	for _, g := range got {
		names = append(names, filepath.Base(g))
	}
	// "-w-apple" is a different folder: only exact or "<slug>-" prefixes match.
	assert.ElementsMatch(t, []string{"-w-app", "-w-app-sub", "-w-app--claude-worktrees-x"}, names)
}

func TestListTranscripts_MainBeforeSubagents(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "-w")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "s1", "subagents"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1", "subagents", "agent-a1.jsonl"), []byte("x\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte("x\n"), 0o600))
	files, err := ListTranscripts([]string{dir})
	require.NoError(t, err)
	require.Len(t, files, 2)
	assert.False(t, files[0].Subagent)
	assert.Equal(t, "s1", files[0].SessionUUID)
	assert.True(t, files[1].Subagent)
	assert.Equal(t, "s1", files[1].SessionUUID)
	assert.Equal(t, "a1", files[1].AgentID)
}

func TestOwnerFolder_LongestWorkbenchWins(t *testing.T) {
	all := []string{"/w", "/w/inner"}
	assert.Equal(t, "", OwnerFolder("/w/inner/x", all, "/w", nil)) // inner owns it
	assert.Equal(t, "/w/inner", OwnerFolder("/w/inner/x", all, "/w/inner", nil))
	assert.Equal(t, "/w", OwnerFolder("/w/other", all, "/w", nil))
	assert.Equal(t, "/w", OwnerFolder("/wt/feature", all, "/w", []string{"/wt/feature"})) // worktree outside
	assert.Equal(t, "", OwnerFolder("/elsewhere", all, "/w", nil))
	assert.Equal(t, "/w", OwnerFolder("/W/Sub", all, "/w", nil)) // APFS: case-insensitive
}

func TestWorktreeRoots(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	assert.Nil(t, WorktreeRoots(context.Background(), t.TempDir())) // not a repository
	repo := t.TempDir()
	wt := filepath.Join(t.TempDir(), "wt")
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "i"},
		{"worktree", "add", "-q", wt},
	} {
		cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
		out, err := cmd.CombinedOutput()
		require.NoError(t, err, string(out))
	}
	got := WorktreeRoots(context.Background(), repo)
	require.Len(t, got, 1)
	resolved, _ := filepath.EvalSymlinks(wt)
	gotResolved, _ := filepath.EvalSymlinks(got[0])
	assert.Equal(t, resolved, gotResolved)
}

// AGENTLOG-04: a symlinked <sid>/subagents directory is never followed.
func TestListTranscripts_SymlinkedSubagentsDirSkipped(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "-w")
	elsewhere := filepath.Join(root, "elsewhere")
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "s1"), 0o755))
	require.NoError(t, os.MkdirAll(elsewhere, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(elsewhere, "agent-a1.jsonl"), []byte("x\n"), 0o600))
	require.NoError(t, os.Symlink(elsewhere, filepath.Join(dir, "s1", "subagents")))
	files, err := ListTranscripts([]string{dir})
	require.NoError(t, err)
	assert.Empty(t, files)
}
