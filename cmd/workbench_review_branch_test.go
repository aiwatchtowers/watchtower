package cmd

import (
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// Board #1012: a review round reads the folder when it is on the task's
// branch, else the task branch's committed tip (read-only), and an open
// round follows the session when its place moves.

func reviewGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	require.True(t, ok)
	c := exec.Command(bin, args...)
	c.Dir = dir
	out, err := c.CombinedOutput()
	require.NoError(t, err, "git %v: %s", args, out)
	return strings.TrimSpace(string(out))
}

// commitOnBranch adds file name on branch (from its current tip) without
// moving the folder off its own branch.
func commitOnBranch(t *testing.T, repo, branch, name string) {
	t.Helper()
	head := reviewGit(t, repo, "symbolic-ref", "--short", "HEAD")
	reviewGit(t, repo, "checkout", "-q", branch)
	require.NoError(t, os.WriteFile(filepath.Join(repo, name), []byte(name+"\n"), 0o644))
	reviewGit(t, repo, "add", name)
	reviewGit(t, repo, "commit", "-q", "-m", name)
	reviewGit(t, repo, "checkout", "-q", head)
}

// ticketTarget makes a target with branch (under parent when set) and binds
// it as the session's ticket (terminal_sessions.target_id) when bind.
func ticketTarget(t *testing.T, database *db.DB, wb, session, parent int64, branch string, bind bool) int64 {
	t.Helper()
	p := sql.NullInt64{Int64: parent, Valid: parent != 0}
	id := db.SeedTestWorkbenchTarget(t, database, wb, p, "T "+branch)
	_, err := database.Exec(`UPDATE targets SET branch = ? WHERE id = ?`, branch, id)
	require.NoError(t, err)
	if bind {
		_, err = database.Exec(`UPDATE terminal_sessions SET target_id = ? WHERE id = ?`, id, session)
		require.NoError(t, err)
	}
	return id
}

func startRound(t *testing.T, wb, s int64, args ...string) map[string]any {
	t.Helper()
	out := reviewJSON(t, wb, "start", append([]string{"--session", itoa(s)}, args...)...)
	require.Equal(t, true, out["ok"], "%v", out)
	return out["round"].(map[string]any)
}

func roundFiles(t *testing.T, wb int64, round map[string]any) []string {
	t.Helper()
	files, _ := reviewJSON(t, wb, "diff", "--round", itoa(int64(round["id"].(float64))))["diff"].(map[string]any)["files"].([]any)
	var out []string
	for _, f := range files {
		out = append(out, f.(map[string]any)["path"].(string))
	}
	return out
}

func TestWorkbenchReview_FolderOnMainReviewsTheTaskBranchTip(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("uncommitted on main\n"), 0o644))

	r := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceBranch, r["source"])
	assert.Equal(t, "feature", r["branch"])
	assert.Equal(t, "main", r["base_label"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "main"), r["base_sha"])
	assert.Equal(t, reviewGit(t, repo, "rev-parse", "feature^{tree}"), r["tree_sha"])
	assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, r), "main's uncommitted edit is not the branch's work")

	// Refresh re-reads the branch: a new commit on it joins the round.
	commitOnBranch(t, repo, "feature", "more.txt")
	again := startRound(t, wb, s, "--refresh")
	assert.Equal(t, r["id"], again["id"])
	assert.Equal(t, []string{"feature.txt", "more.txt"}, roundFiles(t, wb, again))
}

func TestWorkbenchReview_FolderOnTheTaskBranchReviewsTheFolder(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "checkout", "-q", "feature")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("uncommitted\n"), 0o644))

	r := startRound(t, wb, s)
	assert.Equal(t, db.ReviewSourceFolder, r["source"])
	assert.Equal(t, "", r["branch"])
	assert.Equal(t, []string{"README.md", "feature.txt"}, roundFiles(t, wb, r))
}

func TestWorkbenchReview_AncestorBranchAndItsBase(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	reviewGit(t, repo, "branch", "feature-sub", "feature")
	commitOnBranch(t, repo, "feature-sub", "sub.txt")
	group := ticketTarget(t, database, wb, s, 0, "feature", false)
	task := ticketTarget(t, database, wb, s, group, "feature-sub", false)
	leaf := ticketTarget(t, database, wb, s, task, "", true)
	require.NotZero(t, leaf)

	r := startRound(t, wb, s)
	assert.Equal(t, "feature-sub", r["branch"], "the leaf has no branch: its nearest ancestor's")
	assert.Equal(t, "feature", r["base_label"], "the base is the branch above it")
	assert.Equal(t, []string{"sub.txt"}, roundFiles(t, wb, r))
}

func TestWorkbenchReview_NoTaskBranchKeepsTheFolder(t *testing.T) {
	for name, branch := range map[string]string{"no branch anywhere": "", "branch found nowhere": "gone"} {
		t.Run(name, func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			ticketTarget(t, database, wb, s, 0, branch, true)
			require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("edit\n"), 0o644))
			r := startRound(t, wb, s)
			assert.Equal(t, db.ReviewSourceFolder, r["source"])
			assert.Equal(t, []string{"README.md"}, roundFiles(t, wb, r))
		})
	}
}

func TestWorkbenchReview_OriginOnlyTaskBranch(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	tip := reviewGit(t, repo, "rev-parse", "feature")
	reviewGit(t, repo, "update-ref", "refs/remotes/origin/pushed", tip)
	ticketTarget(t, database, wb, s, 0, "pushed", true)
	r := startRound(t, wb, s)
	assert.Equal(t, "pushed", r["branch"])
	assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, r))
}

// The owner's report: the open round stayed "On main" after the session's
// agent moved into the branch's worktree. Start follows the place, keeping
// the round, its comments and its previous-round link.
func TestWorkbenchReview_OpenRoundFollowsTheSessionsPlace(t *testing.T) {
	for _, refresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "start", true: "refresh"}[refresh], func(t *testing.T) {
			database, wb, s, repo := reviewFixture(t)
			commitOnBranch(t, repo, "feature", "feature.txt")
			first := startRound(t, wb, s)
			assert.Equal(t, db.ReviewSourceFolder, first["source"])
			assert.Empty(t, roundFiles(t, wb, first))
			rid := int64(first["id"].(float64))
			_, err := database.Exec(`INSERT INTO review_comments (round_id, path, start_line, end_line, quote, body)
				VALUES (?, 'README.md', 1, 1, 'hello', 'keep me')`, rid)
			require.NoError(t, err)

			// The ticket gets its branch: the round moves to the branch tip.
			ticketTarget(t, database, wb, s, 0, "feature", true)
			args := map[bool][]string{true: {"--refresh"}}[refresh]
			onBranch := startRound(t, wb, s, args...)
			assert.Equal(t, first["id"], onBranch["id"])
			assert.Equal(t, db.ReviewSourceBranch, onBranch["source"])
			assert.Equal(t, []string{"feature.txt"}, roundFiles(t, wb, onBranch))

			// The agent moves into the branch's worktree: the round reads it.
			wt := filepath.Join(t.TempDir(), "wt")
			reviewGit(t, repo, "worktree", "add", "-q", wt, "feature")
			wt, err = filepath.EvalSymlinks(wt)
			require.NoError(t, err)
			require.NoError(t, os.WriteFile(filepath.Join(wt, "wip.txt"), []byte("wip\n"), 0o644))
			_, err = database.Exec(`UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-16T10:00:00Z' WHERE id = ?`, wt, s)
			require.NoError(t, err)
			inWorktree := startRound(t, wb, s, args...)
			assert.Equal(t, first["id"], inWorktree["id"])
			assert.Equal(t, db.ReviewSourceFolder, inWorktree["source"])
			assert.Equal(t, wt, inWorktree["folder_root"])
			assert.Equal(t, []string{"feature.txt", "wip.txt"}, roundFiles(t, wb, inWorktree))

			cs, err := database.ReviewRoundComments(rid)
			require.NoError(t, err)
			require.Len(t, cs, 1)
			assert.Equal(t, "keep me", cs[0].Body)
			assert.Equal(t, 1, reviewRoundCount(t, database))
		})
	}
}

func TestWorkbenchReviewRevertHunk_RefusedOnABranchRound(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	commitOnBranch(t, repo, "feature", "feature.txt")
	ticketTarget(t, database, wb, s, 0, "feature", true)
	r := startRound(t, wb, s)
	require.Equal(t, db.ReviewSourceBranch, r["source"])
	rid := itoa(int64(r["id"].(float64)))
	files := reviewJSON(t, wb, "diff", "--round", rid)["diff"].(map[string]any)["files"].([]any)
	require.Len(t, files, 1)
	hunk := files[0].(map[string]any)["hunks"].([]any)[0].(map[string]any)["hunk_id"].(string)

	out := reviewJSON(t, wb, "revert-hunk", "--round", rid, "--hunk", hunk)
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, errBranchRoundReadOnly.Error(), out["error"])
	assert.Equal(t, 0, revertCount(t, database))
	_, err := os.Stat(filepath.Join(repo, "feature.txt"))
	assert.True(t, os.IsNotExist(err), "nothing written into the folder on main")
}
