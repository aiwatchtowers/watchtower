package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// undoRound: README.md edited, an open round on it; returns the round id and
// the id of its one hunk (from the --since view when since).
func undoRound(t *testing.T, wb, s int64, since bool) (round int64, hunk string) {
	t.Helper()
	round = int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64))
	args := []string{"--round", itoa(round)}
	if since {
		args = append(args, "--since")
	}
	files := reviewJSON(t, wb, "diff", args...)["diff"].(map[string]any)["files"].([]any)
	require.Len(t, files, 1)
	hunks := files[0].(map[string]any)["hunks"].([]any)
	require.Len(t, hunks, 1)
	return round, hunks[0].(map[string]any)["hunk_id"].(string)
}

func readmeOf(t *testing.T, repo string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repo, "README.md"))
	require.NoError(t, err)
	return string(b)
}

func revertCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_reverts`).Scan(&n))
	return n
}

func TestWorkbenchReviewRevertHunk_RecordsOnce(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	original := readmeOf(t, repo)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	round, hunk := undoRound(t, wb, s, false)
	out := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk)
	require.Equal(t, true, out["ok"], "%v", out)
	assert.Equal(t, map[string]any{"hunk_id": hunk, "path": "README.md"}, out["revert"])
	assert.Equal(t, original, readmeOf(t, repo))
	reverts, err := database.ReviewReverts(round)
	require.NoError(t, err)
	require.Len(t, reverts, 1)
	assert.Equal(t, hunk, reverts[0].HunkID)
	assert.Contains(t, reverts[0].Header, "@@ ")
	assert.Contains(t, reverts[0].Patch, "+changed")
	again := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk)
	assert.Equal(t, false, again["ok"])
	assert.Equal(t, "this hunk was already undone in this round", again["error"])
	assert.Equal(t, 1, revertCount(t, database))
}

func TestWorkbenchReviewRevertHunk_SinceView(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("one\n"), 0o644))
	r1 := int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64))
	reviewJSON(t, wb, "send", "--round", itoa(r1))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("two\n"), 0o644))
	round, hunk := undoRound(t, wb, s, true)
	plain := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk)
	assert.Equal(t, "hunk "+hunk+" is not in this round's diff", plain["error"])
	out := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk, "--since")
	require.Equal(t, true, out["ok"], "%v", out)
	assert.Equal(t, "one\n", readmeOf(t, repo))
}

func TestWorkbenchReviewRevertHunk_RefusedWhileAgentWorking(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	round, hunk := undoRound(t, wb, s, false)
	_, err := database.Exec(`UPDATE terminal_sessions SET agent_state = 'working' WHERE id = ?`, s)
	require.NoError(t, err)
	out := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk)
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, "the agent is working in this session — undo when it stops", out["error"])
	assert.Equal(t, "changed\n", readmeOf(t, repo))
	assert.Zero(t, revertCount(t, database))
}

func TestWorkbenchReviewRevertHunk_SentRoundRefused(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	round, hunk := undoRound(t, wb, s, false)
	reviewJSON(t, wb, "send", "--round", itoa(round))
	out := reviewJSON(t, wb, "revert-hunk", "--round", itoa(round), "--hunk", hunk)
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, "the round is not open", out["error"])
	assert.Equal(t, "changed\n", readmeOf(t, repo))
	assert.Zero(t, revertCount(t, database))
}

// Only the owner's Desktop undoes (REVIEW-01): under any agent marker the
// command is refused before it reads or writes anything.
func TestWorkbenchReviewRevertHunk_RefusedUnderAgentMarkers(t *testing.T) {
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
			round, hunk := undoRound(t, wb, s, false)
			t.Setenv(marker, "1")
			_, _, err := runWorkbenchAs(t, "workbench", "review", "revert-hunk", "--workbench", itoa(wb), "--json",
				"--round", itoa(round), "--hunk", hunk)
			resetSetFlags(workbenchReviewCmd.Commands()...)
			require.ErrorContains(t, err, marker)
			assert.Equal(t, "changed\n", readmeOf(t, repo))
			assert.Zero(t, revertCount(t, database))
		})
	}
}
